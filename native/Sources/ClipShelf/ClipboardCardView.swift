import AppKit
import ClipShelfCore
import ImageIO
import UniformTypeIdentifiers

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
    var preview: String { hasPDF && (text.isEmpty || text == "复制的内容") ? title : String(text.prefix(1_000)) }

    static func isPDFType(_ value: String) -> Bool {
        value == "public.pdf" || value == "com.adobe.pdf" || UTType(value)?.conforms(to: .pdf) == true
    }

    init(_ record: ClipboardRecord) {
        id = record.id; text = record.text; sourceApp = record.sourceApp; sourceBundleID = record.sourceBundleID
        copiedAt = record.copiedAt; renamedTitle = record.renamedTitle; ocrText = record.ocrText
        pinboardID = record.pinboardID; revision = record.revision; kind = record.kind
        hasPDF = record.parts.flatMap(\.representations).contains { Self.isPDFType($0.typeIdentifier) }
        title = hasPDF && record.renamedTitle == nil && (record.text.isEmpty || record.text == "复制的内容") ? "扫描文稿（PDF）" : record.title
        hasRichText = record.rtf != nil || record.html != nil
    }

    init(_ metadata: ClipboardRecordMetadata) {
        id = metadata.id; text = metadata.text; sourceApp = metadata.sourceApp; sourceBundleID = metadata.sourceBundleID
        copiedAt = metadata.copiedAt; renamedTitle = metadata.renamedTitle; ocrText = metadata.ocrText
        pinboardID = metadata.pinboardID; revision = metadata.revision; kind = metadata.kind
        hasPDF = metadata.representationTypes.joined().contains { Self.isPDFType($0) }
        title = hasPDF && metadata.renamedTitle == nil && (metadata.text.isEmpty || metadata.text == "复制的内容") ? "扫描文稿（PDF）" : metadata.title
        hasRichText = metadata.representationTypes.joined().contains { ["public.rtf", "public.html", "com.apple.flat-rtfd"].contains($0) }
    }
}

@MainActor
final class ClipboardCardView: NSButton, NSDraggingSource {
    let record: ClipboardCardContent
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var onDragRequested: ((NSEvent) -> Void)?
    private(set) var draggedRecordIDs: [UUID] = []
    var isSelected = false { didSet { updateAppearance() } }

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
        shortcutLabel.stringValue = position < 9 ? "⌘\(position + 1)" : ""
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = .tertiaryLabelColor
        bodyLabel.stringValue = record.preview
        bodyLabel.font = .systemFont(ofSize: compact ? 12 : 15, weight: .regular)
        bodyLabel.textColor = .labelColor
        bodyLabel.maximumNumberOfLines = compact ? 3 : 7
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.cell?.wraps = true
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

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
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((number >> 16) & 0xff) / 255, green: CGFloat((number >> 8) & 0xff) / 255, blue: CGFloat(number & 0xff) / 255, alpha: 1)
    }

    @objc private func pressed() {
        if NSApp.currentEvent?.clickCount == 2 { onOpen?() } else { onSelect?() }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else { onOpen?(); return }
        // Capture the selected group before a plain click changes the selection.
        onSelect?()
        let start = convert(event.locationInWindow, from: nil)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let point = convert(next.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) >= 5 {
                onDragRequested?(next)
                return
            }
        }
    }

    func beginDrag(records: [ClipboardRecord], event: NSEvent) {
        draggedRecordIDs = records.map(\.id)
        var items: [NSDraggingItem] = []
        for record in records {
            let parts = record.parts.isEmpty ? [ClipboardPart(representations: [])] : record.parts
            for (index, part) in parts.enumerated() {
                let writer = NSPasteboardItem()
                for representation in part.representations {
                    writer.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.typeIdentifier))
                }
                writer.setString(record.id.uuidString, forType: NSPasteboard.PasteboardType("io.github.bestbbb.clipshelf.record-id"))
                if index == 0 {
                    if !writer.types.contains(.string), !record.text.isEmpty { writer.setString(record.text, forType: .string) }
                    if !writer.types.contains(.rtf), let rtf = record.rtf { writer.setData(rtf, forType: .rtf) }
                    if !writer.types.contains(.html), let html = record.html { writer.setData(html, forType: .html) }
                }
                guard !writer.types.isEmpty else { continue }
                let dragging = NSDraggingItem(pasteboardWriter: writer)
                let icon = previewImage.image ?? NSImage(systemSymbolName: record.kind == .file ? "doc" : "doc.on.clipboard", accessibilityDescription: "剪贴板内容")
                dragging.setDraggingFrame(NSRect(x: 12, y: 40, width: 120, height: 120), contents: icon)
                items.append(dragging)
            }
        }
        guard !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

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
