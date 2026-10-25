import ClipShelfLocalization
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
        title = hasPDF && record.renamedTitle == nil && (record.text.isEmpty || record.text == "复制的内容") ? L10n.text("扫描文稿（PDF）") : record.title
        hasRichText = record.rtf != nil || record.html != nil
    }

    init(_ metadata: ClipboardRecordMetadata) {
        id = metadata.id; text = metadata.text; sourceApp = metadata.sourceApp; sourceBundleID = metadata.sourceBundleID
        copiedAt = metadata.copiedAt; renamedTitle = metadata.renamedTitle; ocrText = metadata.ocrText
        pinboardID = metadata.pinboardID; revision = metadata.revision; kind = metadata.kind
        hasPDF = metadata.representationTypes.joined().contains { Self.isPDFType($0) }
        hasImageFileParts = Self.hasImageFileParts(metadata.representationTypes)
        title = hasPDF && metadata.renamedTitle == nil && (metadata.text.isEmpty || metadata.text == "复制的内容") ? L10n.text("扫描文稿（PDF）") : metadata.title
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
    private let sourceIcon = NSImageView()
    // Only the five content-kind symbols enter this cache. A cold page should
    // not rebuild the same configured SF Symbol once for every pending icon.
    private static var sourcePlaceholders: [String: NSImage] = [:]
    static let headerHeight: CGFloat = 50
    private var sourceTint: NSColor?
    private let sourceLabel = NSTextField(labelWithString: "")
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private let timeLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let previewImage = CardPreviewImageView()
    private let shortTitleLabel = NSTextField(labelWithString: "")
    private var normalLayoutConstraints: [NSLayoutConstraint] = []
    private var layoutIsConfigured = false
    private var usesShortLayout = true
    private var showsQuickPasteLabel = false
    private let maximumPreviewLines: Int
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateAppearance() } }

    init(record: ClipboardCardContent, position: Int, compact: Bool = false, iconCache: CardIconCache? = nil) {
        self.record = record
        self.position = position
        maximumPreviewLines = compact ? 4 : 9
        super.init(frame: .zero)
        let iconCache = iconCache ?? .shared
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)

        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.wantsLayer = true
        accent.layer?.cornerRadius = 0
        accent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        sourceLabel.stringValue = record.sourceApp ?? L10n.text("剪贴板")
        sourceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sourceLabel.textColor = .white
        sourceLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .white.withAlphaComponent(0.9)
        timeLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.stringValue = ""
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = .tertiaryLabelColor
        bodyLabel.stringValue = record.preview
        bodyLabel.font = Self.looksLikeCode(record)
            ? .monospacedSystemFont(ofSize: compact ? 11 : 12, weight: .regular)
            : .systemFont(ofSize: compact ? 12 : 13, weight: .regular)
        bodyLabel.textColor = record.kind == .link ? .linkColor : .labelColor
        bodyLabel.maximumNumberOfLines = maximumPreviewLines
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.truncatesLastVisibleLine = true
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        shortTitleLabel.stringValue = record.title
        shortTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        shortTitleLabel.textColor = .labelColor
        shortTitleLabel.alignment = .center
        shortTitleLabel.maximumNumberOfLines = 1
        shortTitleLabel.lineBreakMode = .byTruncatingTail
        shortTitleLabel.setAccessibilityIdentifier("clipboard.short-title")
        shortTitleLabel.wantsLayer = true
        shortTitleLabel.layer?.masksToBounds = true
        for label in [sourceLabel, timeLabel, bodyLabel, detailLabel, shortcutLabel, shortTitleLabel] {
            label.isSelectable = false
            label.isEditable = false
        }

        let formatter = Self.relativeDateFormatter
        if formatter.locale.identifier != L10n.locale.identifier { formatter.locale = L10n.locale }
        let kind = Self.contentKind(record)
        let now = Date()
        let elapsed = now.timeIntervalSince(record.copiedAt)
        let relativeTime = abs(elapsed) < 10 ? L10n.text("刚刚") : formatter.localizedString(for: record.copiedAt, relativeTo: now)
        sourceLabel.stringValue = kind
        timeLabel.stringValue = relativeTime
        detailLabel.stringValue = record.kind == .text || record.kind == .link
            ? L10n.text("\(record.text.count) 个字符") : record.title
        toolTip = record.sourceApp ?? L10n.text("剪贴板")
        sourceIcon.toolTip = record.sourceApp ?? L10n.text("剪贴板")
        sourceIcon.setAccessibilityIdentifier("clipboard.source-icon")
        sourceIcon.imageScaling = .scaleProportionallyUpOrDown
        sourceIcon.wantsLayer = true
        if let bundleID = record.sourceBundleID {
            iconCache.request(.application(bundleID)) { [weak self] icon in
                guard let self, let image = icon.image else { return }
                self.sourceIcon.image = image
                self.sourceIcon.imageScaling = .scaleProportionallyUpOrDown
                self.sourceIcon.contentTintColor = nil
                self.sourceTint = icon.tint
                self.updateAppearance()
            }
        }
        if sourceIcon.image == nil {
            sourceIcon.image = Self.sourcePlaceholder(for: record)
            sourceIcon.imageScaling = .scaleNone
            sourceIcon.contentTintColor = .white.withAlphaComponent(0.85)
        }
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        previewImage.setAccessibilityIdentifier("clipboard.preview")
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.isEditable = false
        previewImage.wantsLayer = true
        previewImage.layer?.cornerRadius = 8
        previewImage.layer?.masksToBounds = true
        previewImage.layer?.borderWidth = 0.5
        previewImage.setAccessibilityLabel(L10n.text("\(kind)预览"))
        switch record.kind {
        case .image:
            previewImage.image = NSImage(systemSymbolName: "photo", accessibilityDescription: L10n.text("图片预览正在读取"))
            bodyLabel.isHidden = true
        case .color:
            previewImage.layer?.backgroundColor = Self.hexColor(record.text)?.cgColor
            bodyLabel.isHidden = true
            detailLabel.stringValue = record.text.uppercased()
            detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        case .file:
            // A type icon and file name read faster than a full path, as in Paste.
            let paths = record.text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let first = URL(fileURLWithPath: paths.first ?? record.text)
            let type = UTType(filenameExtension: first.pathExtension) ?? (first.hasDirectoryPath ? .folder : .data)
            iconCache.request(.fileType(type.identifier)) { [weak self] icon in
                guard let image = icon.image else { return }
                self?.previewImage.image = image
            }
            if previewImage.image == nil { previewImage.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) }
            previewImage.imageScaling = .scaleProportionallyUpOrDown
            previewImage.layer?.borderWidth = 0
            previewImage.layer?.cornerRadius = 0
            bodyLabel.isHidden = true
            detailLabel.stringValue = paths.count > 1
                ? L10n.text("\(first.lastPathComponent) 等 \(paths.count) 个文件") : first.lastPathComponent
            detailLabel.lineBreakMode = .byTruncatingMiddle
            toolTip = paths.joined(separator: "\n")
        default:
            previewImage.isHidden = true
        }

        for child in [accent, sourceLabel, timeLabel, sourceIcon, shortcutLabel, previewImage, bodyLabel, detailLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        // The short title uses a bounded frame, so even a one-point viewport
        // never forces an intrinsic text height or a negative image height.
        addSubview(shortTitleLabel)
        normalLayoutConstraints = [
            accent.leadingAnchor.constraint(equalTo: leadingAnchor),
            accent.trailingAnchor.constraint(equalTo: trailingAnchor),
            accent.topAnchor.constraint(equalTo: topAnchor),
            accent.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            sourceLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            sourceLabel.topAnchor.constraint(equalTo: accent.topAnchor, constant: 9),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceIcon.leadingAnchor, constant: -8),
            timeLabel.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 1),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceIcon.leadingAnchor, constant: -8),
            sourceIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sourceIcon.centerYAnchor.constraint(equalTo: accent.centerYAnchor),
            sourceIcon.widthAnchor.constraint(equalToConstant: 34),
            sourceIcon.heightAnchor.constraint(equalToConstant: 34),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            shortcutLabel.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyLabel.topAnchor.constraint(equalTo: accent.bottomAnchor, constant: 12),
            bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: detailLabel.topAnchor, constant: -10),
            previewImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previewImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            previewImage.topAnchor.constraint(equalTo: accent.bottomAnchor, constant: 12),
            previewImage.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -10),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ]
        setAccessibilityLabel("\(record.sourceApp ?? L10n.text("剪贴板"))，\(kind)，\(record.text.prefix(140))")
        setAccessibilityHelp(L10n.text("单击粘贴；⌘/Shift 单击多选；回车粘贴，Shift 回车以纯文本粘贴。"))
        InterfaceLayout.apply(to: self)
        layoutIsConfigured = true
        applyLayoutMode(for: bounds.height)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Native tooltip/tracking registries can outlive a removed collection item.
    /// Retire them before detaching the view, instead of waiting for deinit.
    func retirePresentation() {
        cancelPendingDrag()
        func unregister(_ view: NSView) {
            view.toolTip = nil
            view.removeAllToolTips()
            view.subviews.forEach(unregister)
        }
        unregister(self)
        if let tracking { removeTrackingArea(tracking); self.tracking = nil }
        menu = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Retire the tall-card constraints before AppKit receives a short frame.
        if layoutIsConfigured, newSize.height < 120 { applyLayoutMode(for: newSize.height) }
        super.setFrameSize(newSize)
        if layoutIsConfigured {
            applyLayoutMode(for: newSize.height)
            needsLayout = true
        }
    }

    override func layout() {
        if layoutIsConfigured { applyLayoutMode(for: bounds.height) }
        super.layout()
        if !usesShortLayout {
            if let font = bodyLabel.font {
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                let available = max(0, bounds.height - Self.headerHeight - 12 - 10 - detailLabel.intrinsicContentSize.height - 11)
                let lines = max(1, min(maximumPreviewLines, Int(available / max(1, lineHeight))))
                if bodyLabel.maximumNumberOfLines != lines { bodyLabel.maximumNumberOfLines = lines }
            }
            return
        }
        let inset = min(15, max(0, bounds.width / 4))
        let height = min(max(0, bounds.height), max(0, shortTitleLabel.intrinsicContentSize.height))
        shortTitleLabel.frame = NSRect(x: bounds.minX + inset, y: bounds.midY - height / 2,
                                      width: max(0, bounds.width - inset * 2), height: height)
    }

    private func applyLayoutMode(for height: CGFloat) {
        let shortened = height < 120
        if shortened {
            NSLayoutConstraint.deactivate(normalLayoutConstraints)
        } else if usesShortLayout {
            NSLayoutConstraint.activate(normalLayoutConstraints)
        }
        usesShortLayout = shortened
        accent.isHidden = shortened
        sourceLabel.isHidden = shortened
        timeLabel.isHidden = shortened
        sourceIcon.isHidden = shortened
        shortcutLabel.isHidden = shortened || !showsQuickPasteLabel
        detailLabel.isHidden = shortened
        let showsPreview = record.kind == .image || record.kind == .color || record.kind == .file
        bodyLabel.isHidden = shortened || showsPreview
        previewImage.isHidden = shortened || !showsPreview
        shortTitleLabel.isHidden = !shortened
    }

    private static func contentKind(_ record: ClipboardCardContent) -> String {
        if record.hasPDF { return L10n.text("PDF 文稿") }
        switch record.kind {
        case .text: return record.hasRichText ? L10n.text("富文本") : L10n.text("文本")
        case .link: return L10n.text("链接")
        case .image: return L10n.text("图片")
        case .file: return L10n.text("文件")
        case .color: return L10n.text("颜色")
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
        previewImage.fillsBounds = image != nil
        if let image { previewImage.image = image }
        else { previewImage.image = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: L10n.text("无法显示图片预览")) }
        updateAppearance()
    }

    static func hexColor(_ value: String) -> NSColor? {
        ClipboardEditPlan.color(from: value)
    }

    func setQuickPasteLabel(_ value: String?) {
        shortcutLabel.stringValue = value ?? ""
        showsQuickPasteLabel = value != nil
        shortcutLabel.isHidden = usesShortLayout || !showsQuickPasteLabel
        shortcutLabel.setAccessibilityLabel(value.map { "Quick Paste \($0)" })
    }

    @objc private func pressed() {
        onOpen?([])
    }

    // All children are decorative; the card owns selection and drag gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        trace("mouseDown clicks=\(event.clickCount) event=\(event.eventNumber) flags=\(event.modifierFlags.rawValue)")
        resetDragGesture()
        // The first release already activates the card; a second click must not paste twice.
        guard event.clickCount < 2 else { return }
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
            if wasClick, event.clickCount < 2, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(event) }
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
        let icon = previewImage.image ?? NSImage(systemSymbolName: record.kind == .file ? "doc" : "doc.on.clipboard", accessibilityDescription: L10n.text("剪贴板内容"))
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
            accent.layer?.backgroundColor = headerColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            let idle = NSColor.separatorColor.withAlphaComponent(isHovered ? 1 : 0.55)
            layer?.borderColor = (isSelected ? NSColor.controlAccentColor : idle).cgColor
            layer?.borderWidth = isSelected ? 2 : (isHovered ? 1 : 0.5)
            previewImage.layer?.borderColor = NSColor.separatorColor.cgColor
            if record.kind == .image {
                previewImage.layer?.backgroundColor = previewImage.fillsBounds ? nil : NSColor.quaternaryLabelColor.cgColor
            }
        }
        setAccessibilityValue(isSelected ? L10n.text("已选中") : "")
    }

    /// The source app's own colour identifies a card at a glance, as in Paste.
    /// Sources without a usable icon hue keep a consistent content-type palette.
    private var headerColor: NSColor {
        if let sourceTint { return sourceTint }
        switch record.kind {
        case .text: return NSColor(srgbRed: 0.20, green: 0.40, blue: 0.72, alpha: 1)
        case .link: return NSColor(srgbRed: 0.05, green: 0.44, blue: 0.50, alpha: 1)
        case .image: return NSColor(srgbRed: 0.33, green: 0.32, blue: 0.58, alpha: 1)
        case .file: return NSColor(srgbRed: 0.38, green: 0.40, blue: 0.45, alpha: 1)
        case .color: return NSColor(srgbRed: 0.45, green: 0.32, blue: 0.52, alpha: 1)
        }
    }

    private static func symbolName(for record: ClipboardCardContent) -> String {
        switch record.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }

    private static func sourcePlaceholder(for record: ClipboardCardContent) -> NSImage? {
        let name = symbolName(for: record)
        if let cached = sourcePlaceholders[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        sourcePlaceholders[name] = image
        return image
    }

    /// Coalesces with visible-card requests; a cold card always has a placeholder.
    static func prewarmSourceIcons<S: Sequence>(_ bundleIDs: S) where S.Element == String {
        for bundleID in Set(bundleIDs).prefix(64) { CardIconCache.shared.request(.application(bundleID)) }
    }

    /// Indented or brace-structured text reads better in a fixed-width face.
    static func looksLikeCode(_ record: ClipboardCardContent) -> Bool {
        guard record.kind == .text else { return false }
        let lines = record.preview.split(separator: "\n", omittingEmptySubsequences: true).prefix(12)
        guard lines.count > 1 else { return false }
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        let structural = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix("{") || trimmed.hasSuffix(";") || trimmed == "}" || trimmed.hasSuffix("):")
        }.count
        return indented >= 1 && structural >= 1 || structural >= 2
    }

    /// Averages the colourful pixels of an app icon and darkens the result until
    /// white header text keeps a WCAG contrast ratio of at least 4.5:1.
    /// Monochrome dark icons map to graphite; light grey icons return `nil`.
    nonisolated static func headerTint(for icon: NSImage) -> NSColor? {
        let side = 16
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        var opaque = 0, brightnessSum = 0.0
        for y in 0..<side {
            for x in 0..<side {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.6 else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                pixel.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                opaque += 1; brightnessSum += Double(brightness)
                let w = Double(saturation * brightness)
                guard w > 0.12 else { continue }
                red += Double(pixel.redComponent) * w; green += Double(pixel.greenComponent) * w
                blue += Double(pixel.blueComponent) * w; weight += w
            }
        }
        guard opaque > 0 else { return nil }
        guard weight > Double(opaque) * 0.08 else {
            return brightnessSum / Double(opaque) < 0.4 ? NSColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1) : nil
        }
        let average = NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Darkened yellow turns olive. Nudge yellow icons (Notes, Stickies) toward
        // amber so the readable shade stays warm instead of muddy.
        if (0.09...0.20).contains(hue) { hue = 0.075 }
        saturation = min(max(saturation, 0.45), 0.78)
        brightness = min(brightness, 0.66)
        var tint = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        while contrastWithWhite(tint) < 4.5, brightness > 0.2 {
            brightness -= 0.02
            tint = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        }
        return tint
    }

    nonisolated static func contrastWithWhite(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return 1.05 / (luminance + 0.05)
    }
}

/// Thumbnails fill the preview like a photo crop; placeholder symbols stay centred.
final class CardPreviewImageView: NSImageView {
    var fillsBounds = false { didSet { if fillsBounds != oldValue { needsDisplay = true } } }
    override var wantsUpdateLayer: Bool { fillsBounds ? false : super.wantsUpdateLayer }
    override func draw(_ dirtyRect: NSRect) {
        guard fillsBounds, let image, image.size.width > 0, image.size.height > 0 else {
            super.draw(dirtyRect); return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}
