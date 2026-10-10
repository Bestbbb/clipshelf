import AppKit
import ClipShelfCore
import ClipShelfLocalization

/// A separate native drag type prevents a board gesture from becoming clipboard content.
@MainActor
final class PinboardTabStrip: NSView {
    static let dragType = NSPasteboard.PasteboardType("io.github.bestbbb.clipshelf.pinboard-tab")
    var onSelect: ((UUID?) -> Void)?
    var onReorder: ((_ ids: [UUID], _ expectedOrder: [UUID]) -> Void)?
    var isSaving = false {
        didSet { if isSaving { cancelDrag() } }
    }

    private(set) var pinboards: [Pinboard] = []
    private(set) var selectedIDs: Set<UUID> = []
    var selectedID: UUID? { selectedIDs.count == 1 ? selectedIDs.first : nil }
    private(set) var tabButtons: [PinboardTabButton] = []
    let allButton = NSButton(title: L10n.text("全部内容"), target: nil, action: nil)
    let scrollView = NSScrollView()
    private let document = PinboardTabDocument()
    private let insertionLine = NSView()
    private var pending: (boards: [Pinboard], selectedIDs: Set<UUID>)?
    private var edgeTimer: Timer?
    private var pointerInViewport: NSPoint?
    private var lastLayoutDirection: NSUserInterfaceLayoutDirection?
    private var revealSelectionAfterLayout = true

    private struct Gesture {
        let id = UUID()
        let source: PinboardTabButton
        let boardID: UUID
        let order: [UUID]
        let frames: [NSRect]
        let contentWidth: CGFloat
        let direction: NSUserInterfaceLayoutDirection
        var consumed = false
    }
    private var gesture: Gesture?
    var activeDragID: UUID? { gesture?.id }
    var isShowingInsertion: Bool { !insertionLine.isHidden }

    init(layoutDirection: NSUserInterfaceLayoutDirection? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("分组"))
        allButton.bezelStyle = .inline
        allButton.setButtonType(.toggle)
        allButton.font = .systemFont(ofSize: 12, weight: .semibold)
        allButton.target = self
        allButton.action = #selector(selectAllBoards)
        allButton.setAccessibilityIdentifier("pinboard.all")
        addSubview(allButton)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        document.owner = self
        document.registerForDraggedTypes([Self.dragType])
        addSubview(scrollView)
        insertionLine.wantsLayer = true
        insertionLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionLine.layer?.cornerRadius = 1
        insertionLine.isHidden = true
        document.addSubview(insertionLine)
        InterfaceLayout.apply(to: self, direction: layoutDirection)
        setPinboards([], selectedID: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    func setPinboards(_ boards: [Pinboard], selectedID: UUID?) {
        setPinboards(boards, selectedIDs: Set(selectedID.map { [$0] } ?? []))
    }

    func setPinboards(_ boards: [Pinboard], selectedIDs: Set<UUID>) {
        guard Set(boards.map(\.id)).count == boards.count else { cancelDrag(); return }
        if gesture != nil {
            // Keep hit targets under the pointer fixed until the native gesture ends.
            pending = (boards, selectedIDs)
            if boards.map(\.id) != gesture?.order { clearInsertion() }
            return
        }
        install(boards, selectedIDs: selectedIDs)
    }

    private func install(_ boards: [Pinboard], selectedIDs: Set<UUID>) {
        let newSelection = selectedIDs.intersection(Set(boards.map(\.id)))
        revealSelectionAfterLayout = newSelection.count == 1
            && (revealSelectionAfterLayout || self.selectedIDs != newSelection || pinboards.isEmpty)
        pinboards = boards
        self.selectedIDs = newSelection
        let existing = Dictionary(uniqueKeysWithValues: tabButtons.map { ($0.boardID, $0) })
        for button in tabButtons where !boards.contains(where: { $0.id == button.boardID }) { button.removeFromSuperview() }
        tabButtons = boards.map { board in
            let button = existing[board.id] ?? PinboardTabButton(board: board, owner: self)
            button.update(board, selected: newSelection.contains(board.id))
            if button.superview == nil { document.addSubview(button, positioned: .below, relativeTo: insertionLine) }
            return button
        }
        allButton.state = newSelection.isEmpty ? .on : .off
        InterfaceLayout.apply(to: self, direction: userInterfaceLayoutDirection)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let direction = userInterfaceLayoutDirection
        if let gesture, gesture.direction != direction { cancelDrag() }
        let allWidth = min(max(75, allButton.fittingSize.width + 16), max(0, bounds.width - 32))
        let height = min(30, bounds.height)
        let top = max(0, (bounds.height - height) / 2)
        let available = max(0, bounds.width - allWidth - 10)
        allButton.frame = NSRect(x: direction == .rightToLeft ? bounds.width - allWidth : 0,
                                 y: top, width: allWidth, height: height)
        scrollView.frame = NSRect(x: direction == .rightToLeft ? 0 : allWidth + 10,
                                  y: top, width: available, height: height)
        if let gesture {
            document.frame = NSRect(x: 0, y: 0, width: gesture.contentWidth, height: height)
            for (button, frame) in zip(tabButtons, gesture.frames) { button.frame = frame }
            return
        }
        let widths = tabButtons.map { min(240, max(58, $0.fittingSize.width + 18)) }
        let totalWidth = max(available, widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 6)
        document.frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)
        var position: CGFloat = 0
        for (button, width) in zip(tabButtons, widths) {
            button.frame = NSRect(x: direction == .rightToLeft ? totalWidth - position - width : position,
                                  y: 0, width: width, height: height)
            position += width + 6
        }
        let directionChanged = lastLayoutDirection != direction
        lastLayoutDirection = direction
        if selectedIDs.count <= 1, revealSelectionAfterLayout || directionChanged {
            if let selected = tabButtons.first(where: { $0.boardID == selectedID }) {
                document.scrollToVisible(selected.frame)
            } else {
                scrollView.contentView.scroll(to: NSPoint(x: direction == .rightToLeft ? max(0, totalWidth - available) : 0, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            revealSelectionAfterLayout = false
        }
    }

    @objc private func selectAllBoards() { onSelect?(nil) }

    func beginGesture(from source: PinboardTabButton) -> UUID? {
        cancelDrag()
        guard !isSaving, onReorder != nil, source.owner === self,
              tabButtons.contains(where: { $0 === source }), pinboards.count > 1 else { return nil }
        layoutSubtreeIfNeeded()
        let value = Gesture(source: source, boardID: source.boardID, order: pinboards.map(\.id),
                            frames: tabButtons.map(\.frame), contentWidth: document.bounds.width,
                            direction: userInterfaceLayoutDirection)
        gesture = value
        return value.id
    }

    private func ownedGesture(_ source: Any?) -> Gesture? {
        guard !isSaving, let value = gesture, !value.consumed,
              let source = source as? PinboardTabButton, source === value.source, source.owner === self,
              source.gestureID == value.id, value.direction == userInterfaceLayoutDirection,
              (pending?.boards.map(\.id) ?? pinboards.map(\.id)) == value.order else { return nil }
        return value
    }

    func updateDrag(at point: NSPoint, source: Any?) -> NSDragOperation {
        guard let value = ownedGesture(source) else { clearInsertion(); return [] }
        pointerInViewport = NSPoint(x: point.x - scrollView.contentView.bounds.minX, y: point.y)
        let index = PanelLayoutDirection.insertionIndex(at: point.x, frames: value.frames, direction: value.direction)
        let plan = PinboardTabReorderPlan.moving(value.boardID, in: value.order, toInsertionIndex: index)
        if plan != nil, let frame = index < value.frames.count ? value.frames[index] : value.frames.last {
            insertionLine.frame = PanelLayoutDirection.insertionLineFrame(frame: frame, before: index < value.frames.count,
                direction: value.direction, contentWidth: document.bounds.width).insetBy(dx: 0, dy: 3)
            insertionLine.isHidden = false
        } else { insertionLine.isHidden = true }
        startEdgeScrolling()
        return .move
    }

    @discardableResult
    func acceptDrop(at point: NSPoint, source: Any?) -> Bool {
        guard let value = ownedGesture(source) else { clearInsertion(); return false }
        let index = PanelLayoutDirection.insertionIndex(at: point.x, frames: value.frames, direction: value.direction)
        guard let plan = PinboardTabReorderPlan.moving(value.boardID, in: value.order, toInsertionIndex: index),
              let onReorder else { clearInsertion(); return false }
        gesture?.consumed = true
        clearInsertion()
        // No speculative list is installed. The caller returns authoritative boards after saving.
        onReorder(plan.ids, plan.expectedOrder)
        return true
    }

    func endGesture(_ id: UUID?) {
        guard let id, gesture?.id == id else { return }
        cancelDrag()
    }

    func cancelDrag() {
        let source = gesture?.source
        gesture = nil
        clearInsertion()
        source?.invalidateGesture()
        if let pending {
            self.pending = nil
            install(pending.boards, selectedIDs: pending.selectedIDs)
        }
        needsLayout = true
    }

    func clearInsertion() {
        insertionLine.isHidden = true
        pointerInViewport = nil
        edgeTimer?.invalidate()
        edgeTimer = nil
    }

    private func startEdgeScrolling() {
        guard edgeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceEdgeScrolling() }
        }
        edgeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Uses physical viewport coordinates; scrolling never reverses the logical board order.
    func advanceEdgeScrolling() {
        guard let value = gesture, ownedGesture(value.source) != nil, let pointer = pointerInViewport else {
            clearInsertion(); return
        }
        let clip = scrollView.contentView
        let movement = Self.edgeScrollDelta(pointerX: pointer.x, viewportWidth: clip.bounds.width)
        guard movement != 0 else { return }
        let x = min(max(0, clip.bounds.minX + movement), max(0, document.bounds.width - clip.bounds.width))
        guard x != clip.bounds.minX else { return }
        clip.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(clip)
        _ = updateDrag(at: NSPoint(x: x + pointer.x, y: pointer.y), source: value.source)
    }

    static func edgeScrollDelta(pointerX: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth > 0, pointerX >= 0, pointerX <= viewportWidth else { return 0 }
        let edge = min(28, viewportWidth / 3)
        if pointerX < edge { return -18 * (1 - pointerX / edge) }
        if pointerX > viewportWidth - edge { return 18 * (1 - (viewportWidth - pointerX) / edge) }
        return 0
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func cancelOperation(_ sender: Any?) { cancelDrag() }
    deinit { edgeTimer?.invalidate() }
}

@MainActor
final class PinboardTabButton: NSButton, NSDraggingSource {
    let boardID: UUID
    weak var owner: PinboardTabStrip?
    private(set) var gestureID: UUID?
    private var mouseOrigin = NSPoint.zero
    private var pressed = false
    private var suppressClick = false
    private var nativeDragging = false

    init(board: Pinboard, owner: PinboardTabStrip) {
        boardID = board.id
        self.owner = owner
        super.init(frame: .zero)
        bezelStyle = .inline
        setButtonType(.toggle)
        font = .systemFont(ofSize: 12, weight: .medium)
        imagePosition = .imageLeading
        cell?.lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(activate)
        update(board, selected: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ board: Pinboard, selected: Bool) {
        title = board.name
        toolTip = board.name
        state = selected ? .on : .off
        setAccessibilityLabel(board.name)
        setAccessibilityIdentifier("pinboard.\(boardID.uuidString)")
        let color = ClipboardCardView.hexColor(board.color) ?? .controlAccentColor
        image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
    @objc private func activate() { owner?.onSelect?(boardID) }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        owner?.cancelDrag()
        pressed = true
        suppressClick = false
        nativeDragging = false
        mouseOrigin = event.locationInWindow
        gestureID = owner?.beginGesture(from: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, !nativeDragging,
              hypot(event.locationInWindow.x - mouseOrigin.x, event.locationInWindow.y - mouseOrigin.y) >= 5 else { return }
        suppressClick = true
        guard let gestureID, owner?.activeDragID == gestureID, window?.isVisible == true else { return }
        let marker = NSPasteboardItem()
        marker.setString("clipshelf-pinboard-tab", forType: PinboardTabStrip.dragType)
        let item = NSDraggingItem(pasteboardWriter: marker)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(bounds, contents: image)
        nativeDragging = true
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !nativeDragging else { return }
        let click = pressed && !suppressClick && window?.isVisible == true
            && bounds.contains(convert(event.locationInWindow, from: nil))
        owner?.endGesture(gestureID)
        invalidateGesture()
        if click { activate() }
    }

    func invalidateGesture() { gestureID = nil; pressed = false; suppressClick = true }
    override func cancelOperation(_ sender: Any?) { owner?.cancelDrag(); invalidateGesture() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { owner?.endGesture(gestureID); invalidateGesture() }
        super.viewWillMove(toWindow: newWindow)
    }
    func dragOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication && gestureID != nil ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dragOperationMask(for: context)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner?.endGesture(gestureID)
        nativeDragging = false
        invalidateGesture()
    }
}

@MainActor
private final class PinboardTabDocument: NSView {
    weak var owner: PinboardTabStrip?
    override var isFlipped: Bool { true }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.updateDrag(at: convert(sender.draggingLocation, from: nil), source: sender.draggingSource) ?? []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { owner?.clearInsertion() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { owner?.clearInsertion() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingUpdated(sender) == .move
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        owner?.acceptDrop(at: convert(sender.draggingLocation, from: nil), source: sender.draggingSource) ?? false
    }
}
