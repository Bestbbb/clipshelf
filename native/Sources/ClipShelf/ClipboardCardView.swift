import AppKit
import ClipShelfCore
import ImageIO
import UniformTypeIdentifiers

/// Opt-in event diagnostics: never include record IDs, titles, URLs, or payload bytes.
@MainActor
enum ClipboardDragTrace {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--trace-drag")
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[ClipShelf drag \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// A presentation-only value. It intentionally contains no clipboard payload bytes.
struct ClipboardCardContent {
    let id: UUID
    let text: String
    let sourceApp: String?
    let sourceBundleID: String?
    let copiedAt: Date
    let renamedTitle: String?
    let ocrText: String?
    let pinboardID: UUID?
    let revision: Int
    let kind: ClipboardContentKind
    let title: String
    let hasRichText: Bool
    let hasPDF: Bool
    let hasImageFileParts: Bool
    var preview: String { hasPDF && (text.isEmpty || text == "复制的内容") ? title : String(text.prefix(1_000)) }

    static func isPDFType(_ value: String) -> Bool {
        value == "public.pdf" || value == "com.adobe.pdf" || UTType(value)?.conforms(to: .pdf) == true
    }

    init(_ record: ClipboardRecord) {
        id = record.id; text = record.text; sourceApp = record.sourceApp; sourceBundleID = record.sourceBundleID
        copiedAt = record.copiedAt; renamedTitle = record.renamedTitle; ocrText = record.ocrText
        pinboardID = record.pinboardID; revision = record.revision; kind = record.kind
        hasPDF = record.parts.flatMap(\.representations).contains { Self.isPDFType($0.typeIdentifier) }
        hasImageFileParts = Self.hasImageFileParts(record.parts.map { $0.representations.map(\.typeIdentifier) })
        title = hasPDF && record.renamedTitle == nil && (record.text.isEmpty || record.text == "复制的内容") ? "扫描文稿（PDF）" : record.title
        hasRichText = record.rtf != nil || record.html != nil
    }

    init(_ metadata: ClipboardRecordMetadata) {
        id = metadata.id; text = metadata.text; sourceApp = metadata.sourceApp; sourceBundleID = metadata.sourceBundleID
        copiedAt = metadata.copiedAt; renamedTitle = metadata.renamedTitle; ocrText = metadata.ocrText
        pinboardID = metadata.pinboardID; revision = metadata.revision; kind = metadata.kind
        hasPDF = metadata.representationTypes.joined().contains { Self.isPDFType($0) }
        hasImageFileParts = Self.hasImageFileParts(metadata.representationTypes)
        title = hasPDF && metadata.renamedTitle == nil && (metadata.text.isEmpty || metadata.text == "复制的内容") ? "扫描文稿（PDF）" : metadata.title
        hasRichText = metadata.representationTypes.joined().contains { ["public.rtf", "public.html", "com.apple.flat-rtfd"].contains($0) }
    }

    private static func hasImageFileParts(_ parts: [[String]]) -> Bool {
        parts.contains { types in
            !types.contains(where: ClipboardFileAccess.isFileURLType) &&
            types.contains { UTType($0)?.conforms(to: .image) == true }
        }
    }
}

@MainActor
final class ClipboardCardView: NSButton, NSDraggingSource {
    let record: ClipboardCardContent
    let position: Int
    var onSelect: (() -> Void)?
    var onClick: ((NSEvent) -> Void)?
    var onOpen: ((NSEvent.ModifierFlags) -> Void)?
    var onPrepareDrag: ((NSEvent) -> Void)?
    var onDragError: ((Error) -> Void)?
    var publications: OwnedFilePublicationCoordinator?
    private(set) var activeGestureID: UUID?
    private(set) var draggedRecordIDs: [UUID] = []
    private(set) var draggedRecordRevisions: [UUID: Int] = [:]
    var dragOriginID: UUID?
    private(set) var dragScopeID: UUID?
    private(set) var dragSelectionID: UUID?
    private(set) var draggedReferences: [ClipboardSelectionReference] = []
    var isSelected = false { didSet { updateAppearance() } }

    static let recordIDType = NSPasteboard.PasteboardType("io.github.bestbbb.clipshelf.record-id")
    private enum DragKind { case ordering, payload }
    private var dragKind: DragKind?
    private var preparedWriters: [any NSPasteboardWriting] = []
    private var preparedOwnedLease: OwnedAssetLease?
    private var mouseDownLocation = NSPoint.zero
    private var latestDragEvent: NSEvent?
    private var isDragging = false

    private let accent = NSView()
    private let sourceLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let previewImage = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateAppearance() } }

    init(record: ClipboardCardContent, position: Int, compact: Bool = false) {
        self.record = record
        self.position = position
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)

        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.wantsLayer = true
        accent.layer?.cornerRadius = 2
        accent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        sourceLabel.stringValue = record.sourceApp ?? "剪贴板"
        sourceLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.stringValue = ""
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = .tertiaryLabelColor
        bodyLabel.stringValue = record.preview
        bodyLabel.font = .systemFont(ofSize: compact ? 12 : 15, weight: .regular)
        bodyLabel.textColor = .labelColor
        bodyLabel.maximumNumberOfLines = compact ? 3 : 7
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.cell?.wraps = true
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for label in [sourceLabel, bodyLabel, detailLabel, shortcutLabel] {
            label.isSelectable = false
            label.isEditable = false
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let kind = Self.contentKind(record)
        let elapsed = Date().timeIntervalSince(record.copiedAt)
        let relativeTime = abs(elapsed) < 10 ? "刚刚" : formatter.localizedString(for: record.copiedAt, relativeTo: Date())
        detailLabel.stringValue = "\(kind) · \(relativeTime)"
        detailLabel.font = .systemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.isEditable = false
        previewImage.wantsLayer = true
        previewImage.layer?.cornerRadius = 8
        previewImage.layer?.masksToBounds = true
        previewImage.setAccessibilityLabel("\(kind)预览")
        switch record.kind {
        case .image:
            previewImage.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "图片预览正在读取")
            bodyLabel.isHidden = true
        case .color:
            previewImage.layer?.backgroundColor = Self.hexColor(record.text)?.cgColor
            bodyLabel.isHidden = true
            detailLabel.stringValue = "\(record.text) · \(relativeTime)"
        default:
            previewImage.isHidden = true
        }

        for child in [accent, sourceLabel, shortcutLabel, previewImage, bodyLabel, detailLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            accent.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            accent.widthAnchor.constraint(equalToConstant: 4),
            accent.heightAnchor.constraint(equalToConstant: 13),
            sourceLabel.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 7),
            sourceLabel.centerYAnchor.constraint(equalTo: accent.centerYAnchor),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -7),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            shortcutLabel.centerYAnchor.constraint(equalTo: sourceLabel.centerYAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            bodyLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 18),
            bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: detailLabel.topAnchor, constant: -12),
            previewImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            previewImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            previewImage.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 16),
            previewImage.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -12),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15)
        ])
        setAccessibilityLabel("\(sourceLabel.stringValue)，\(kind)，\(record.text.prefix(140))")
        setAccessibilityHelp("单击选择，双击粘贴；回车粘贴，Shift 回车以纯文本粘贴。")
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func contentKind(_ record: ClipboardCardContent) -> String {
        if record.hasPDF { return "PDF 文稿" }
        switch record.kind {
        case .text: return record.hasRichText ? "富文本" : "文本"
        case .link: return "链接"
        case .image: return "图片"
        case .file: return "文件"
        case .color: return "颜色"
        }
    }

    static func thumbnail(for record: ClipboardRecord, maxPixelSize: Int = 512) -> NSImage? {
        guard let image = thumbnailCGImage(for: record, maxPixelSize: maxPixelSize) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    nonisolated static func thumbnailCGImage(for record: ClipboardRecord, maxPixelSize: Int = 512) -> CGImage? {
        for representation in record.parts.flatMap(\.representations) where UTType(representation.typeIdentifier)?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithData(representation.data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary) else { continue }
            return image
        }
        return nil
    }

    func applyThumbnail(_ image: NSImage?) {
        if let image { previewImage.image = image }
        else { previewImage.image = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: "无法显示图片预览") }
    }

    static func hexColor(_ value: String) -> NSColor? {
        ClipboardEditPlan.color(from: value)
    }

    func setQuickPasteLabel(_ value: String?) {
        shortcutLabel.stringValue = value ?? ""
        shortcutLabel.isHidden = value == nil
        shortcutLabel.setAccessibilityLabel(value.map { "Quick Paste \($0)" })
    }

    @objc private func pressed() {
        if NSApp.currentEvent?.clickCount == 2 { onOpen?(NSApp.currentEvent?.modifierFlags ?? []) } else { onSelect?() }
    }

    // All children are decorative; the card owns selection and drag gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        trace("mouseDown clicks=\(event.clickCount) event=\(event.eventNumber) flags=\(event.modifierFlags.rawValue)")
        resetDragGesture()
        guard event.clickCount < 2 else { onOpen?(event.modifierFlags); return }
        activeGestureID = UUID()
        mouseDownLocation = event.locationInWindow
        onSelect?()
        // Start payload reads before the drag threshold, without a nested event loop.
        onPrepareDrag?(event)
        trace("mouseDown prepared")
    }

    override func mouseDragged(with event: NSEvent) {
        trace("mouseDragged event=\(event.eventNumber) dx=\(event.locationInWindow.x - mouseDownLocation.x) dy=\(event.locationInWindow.y - mouseDownLocation.y)")
        guard activeGestureID != nil, !isDragging,
              hypot(event.locationInWindow.x - mouseDownLocation.x, event.locationInWindow.y - mouseDownLocation.y) >= 5 else { return }
        latestDragEvent = event
        startPreparedDragIfReady()
    }

    override func mouseUp(with event: NSEvent) {
        trace("mouseUp event=\(event.eventNumber)")
        if !isDragging {
            let wasClick = activeGestureID != nil && latestDragEvent == nil
            resetDragGesture()
            if wasClick { onClick?(event) }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelPendingDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func cancelOperation(_ sender: Any?) { cancelPendingDrag() }

    func cancelPendingDrag() {
        trace("cancelPendingDrag")
        if !isDragging { resetDragGesture(); return }
        // A native session retains its source metadata until endedAt, but can never restart.
        activeGestureID = nil
        latestDragEvent = nil
        preparedWriters.removeAll()
        preparedOwnedLease = nil
    }

    func prepareOrderingDrag(contents: [ClipboardCardContent], originID: UUID) {
        prepareOrderingDrag(references: contents.map { ClipboardSelectionReference(id: $0.id, revision: $0.revision) }, originID: originID)
    }

    func prepareOrderingDrag(references: [ClipboardSelectionReference], originID: UUID,
                             scopeID: UUID? = nil, selectionID: UUID? = nil) {
        guard activeGestureID != nil, !references.isEmpty,
              Set(references.map(\.id)).count == references.count else { return }
        dragKind = .ordering
        dragOriginID = originID; dragScopeID = scopeID; dragSelectionID = selectionID
        draggedReferences = references
        draggedRecordIDs = references.map(\.id)
        draggedRecordRevisions = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0.revision) })
        preparedWriters = Self.orderingDragItems(for: references)
        trace("prepareOrderingDrag")
    }

    func preparePayloadDrag(originID: UUID, scopeID: UUID? = nil, selectionID: UUID? = nil) {
        guard activeGestureID != nil else { return }
        dragKind = .payload
        dragOriginID = originID; dragScopeID = scopeID; dragSelectionID = selectionID
        trace("preparePayloadDrag")
    }

    /// Completion belongs to one mouse gesture; a released/replaced gesture cannot start later.
    @discardableResult
    func providePreparedPayload(records: [ClipboardRecord], gestureID: UUID) -> Bool {
        providePreparedWriters(records: records, gestureID: gestureID) {
            try Self.payloadDragItems(for: records)
        }
    }

    @discardableResult
    func providePreparedImageFiles(_ prepared: PreparedImageFileOutput, records: [ClipboardRecord], gestureID: UUID) -> Bool {
        providePreparedWriters(records: records, gestureID: gestureID) { try prepared.draggingWriters() }
    }

    func rejectPreparedPayload(_ error: Error, gestureID: UUID) {
        guard activeGestureID == gestureID, dragKind == .payload, !isDragging else { return }
        resetDragGesture()
        onDragError?(error)
    }

    private func providePreparedWriters(records: [ClipboardRecord], gestureID: UUID,
                                        create: () throws -> [any NSPasteboardWriting]) -> Bool {
        trace("providePreparedPayload count=\(records.count) gestureMatches=\(activeGestureID == gestureID)")
        guard activeGestureID == gestureID, dragKind == .payload, !isDragging else { return false }
        do {
            let lease = try publications?.retain(records)
            preparedWriters = try create()
            preparedOwnedLease = lease
            draggedReferences = records.map { ClipboardSelectionReference(id: $0.id, revision: $0.revision) }
            draggedRecordIDs = records.map(\.id)
            draggedRecordRevisions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.revision) })
            startPreparedDragIfReady()
            return true
        } catch {
            resetDragGesture()
            onDragError?(error)
            return false
        }
    }

    static func orderingDragItems(for contents: [ClipboardCardContent]) -> [NSPasteboardItem] {
        orderingDragItems(for: contents.map { ClipboardSelectionReference(id: $0.id, revision: $0.revision) })
    }

    static func orderingDragItems(for references: [ClipboardSelectionReference]) -> [NSPasteboardItem] {
        guard !references.isEmpty else { return [] }
        // The source object holds the complete refs. Native dragging receives one constant marker.
        let item = NSPasteboardItem()
        item.setString("clipshelf-selection", forType: recordIDType)
        return [item]
    }

    static func payloadDragItems(for records: [ClipboardRecord]) throws -> [NSPasteboardItem] {
        // Preserve each original item's representations and order. Display titles are never payloads.
        try records.flatMap { try ClipboardCodec.items(for: [$0], plainText: false) }
    }

    var hasPreparedDragGesture: Bool {
        activeGestureID != nil && !isDragging && !preparedWriters.isEmpty && latestDragEvent != nil
    }

    private func startPreparedDragIfReady() {
        trace("startPreparedDragIfReady attempt")
        // The window's mouse event sequence owns the gesture. Assistive input can deliver
        // valid mouseDragged events without changing the global physical-button mask.
        guard hasPreparedDragGesture, let event = latestDragEvent, window?.isVisible == true else { return }
        do {
            if let lease = preparedOwnedLease {
                // Register before AppKit exposes any URL. Session endedAt only
                // ends our gesture; the receiver may still be reading the file.
                _ = try publications?.publish(lease: lease, purpose: .drag)
            }
        } catch {
            resetDragGesture()
            onDragError?(error)
            return
        }
        let icon = previewImage.image ?? NSImage(systemSymbolName: record.kind == .file ? "doc" : "doc.on.clipboard", accessibilityDescription: "剪贴板内容")
        let items = preparedWriters.map { writer in
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            dragging.setDraggingFrame(NSRect(x: 12, y: 40, width: 120, height: 120), contents: icon)
            return dragging
        }
        isDragging = true
        trace("beginDraggingSession calling")
        let session = beginDraggingSession(with: items, event: event, source: self)
        trace("beginDraggingSession returned")
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func dragOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        if dragKind == .ordering { return context == .withinApplication ? .move : [] }
        return context == .withinApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        let operation = dragOperationMask(for: context)
        trace("sourceOperation context=\(context == .withinApplication ? "inside" : "outside") mask=\(operation.rawValue)")
        return operation
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { trace("session willBegin") }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        trace("session ended operation=\(operation.rawValue)")
        resetDragGesture()
    }

    private func trace(_ stage: String) {
        ClipboardDragTrace.log("card \(stage) active=\(activeGestureID != nil) kind=\(dragKind == .ordering ? "ordering" : dragKind == .payload ? "payload" : "none") prepared=\(preparedWriters.count) records=\(draggedRecordIDs.count) dragging=\(isDragging) latestEvent=\(latestDragEvent != nil) window=\(window != nil) pressedMouseButtons=\(NSEvent.pressedMouseButtons)")
    }

    private func resetDragGesture() {
        activeGestureID = nil
        dragKind = nil
        preparedWriters = []
        preparedOwnedLease = nil
        latestDragEvent = nil
        isDragging = false
        draggedReferences = []
        draggedRecordIDs = []
        draggedRecordRevisions = [:]
        dragOriginID = nil
        dragScopeID = nil
        dragSelectionID = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let newTracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(newTracking)
        tracking = newTracking
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.09) : NSColor.controlBackgroundColor.withAlphaComponent(isHovered ? 0.95 : 0.72)).cgColor
            layer?.borderColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.75) : NSColor.separatorColor.withAlphaComponent(isHovered ? 0.8 : 0.45)).cgColor
            layer?.borderWidth = isSelected ? 2 : 1
        }
        setAccessibilityValue(isSelected ? "已选中" : "")
    }
}
