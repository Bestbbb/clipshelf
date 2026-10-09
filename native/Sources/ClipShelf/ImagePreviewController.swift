import AppKit
import ClipShelfCore

/// Geometry stays in the oriented image's lower-left coordinate system. AppKit's
/// canvas is deliberately not flipped, so letterboxing and resized views align.
enum ImagePreviewGeometry {
    static func aspectFit(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func rectangle(_ normalized: CGRect, imageRect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + normalized.minX * imageRect.width,
               y: imageRect.minY + normalized.minY * imageRect.height,
               width: normalized.width * imageRect.width, height: normalized.height * imageRect.height)
    }
    static func matches(in region: LocalIntelligenceService.OCRRegion, query: String) -> [CGRect] {
        let terms = query.split(whereSeparator: { $0.isWhitespace || $0 == "\"" }).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let text = region.text as NSString
        var rectangles: [CGRect] = []
        for term in Set(terms) {
            var start = 0
            while start < text.length {
                let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                       range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                let spans = region.spans.filter { NSIntersectionRange(NSRange(location: $0.utf16Location, length: $0.utf16Length), range).length > 0 }
                // Some Vision revisions cannot provide substring bounds. Highlight
                // the actual recognized line in that case, rather than estimating glyph widths.
                let box = spans.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
                let chosen = box.isNull ? region.boundingBox : box
                if !rectangles.contains(chosen) { rectangles.append(chosen) }
                start = range.location + range.length
            }
        }
        return rectangles
    }
}

private final class OCRPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OCRImageCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var regions: [LocalIntelligenceService.OCRRegion] = [] { didSet { needsDisplay = true } }
    var query = "" { didSet { needsDisplay = true } }
    var showsRegions = true { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let imageRect = ImagePreviewGeometry.aspectFit(imageSize: CGSize(width: image.width, height: image.height), in: bounds.insetBy(dx: 12, dy: 12))
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
        for region in regions {
            if showsRegions {
                context.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.7).cgColor)
                context.setLineWidth(1)
                context.stroke(ImagePreviewGeometry.rectangle(region.boundingBox, imageRect: imageRect))
            }
            for match in ImagePreviewGeometry.matches(in: region, query: query) {
                let rect = ImagePreviewGeometry.rectangle(match, imageRect: imageRect)
                context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.35).cgColor)
                context.fill(rect)
                context.setStrokeColor(NSColor.systemOrange.cgColor)
                context.setLineWidth(2); context.stroke(rect)
            }
        }
    }
}

@MainActor
final class ImagePreviewController: NSWindowController, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    var onRotate: (() -> Void)?
    var onExtractText: (() -> Void)?
    private let record: ClipboardRecord
    private let cache: OCRDerivedCache
    private let sourceStore: HistoryStore?
    private let recognizer = LocalIntelligenceService()
    private let canvas = OCRImageCanvas()
    private let status = NSTextField(labelWithString: "正在读取图片…")
    private let query = NSSearchField()
    private let editor = NSTextView()
    private let textScroll = NSScrollView()
    private let fullText = NSButton(checkboxWithTitle: "识别全文", target: nil, action: nil)
    private let regionToggle = NSButton(checkboxWithTitle: "显示识别区域", target: nil, action: nil)
    private let retry = NSButton(title: "重新识别", target: nil, action: nil)
    private let cancel = NSButton(title: "取消识别", target: nil, action: nil)
    private let extract = NSButton(title: "提取为新记录", target: nil, action: nil)
    private let rotate = NSButton(title: "向左旋转", target: nil, action: nil)
    private var work: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var presented = false
    private var result: LocalIntelligenceService.OCRResult?

    init(record: ClipboardRecord, searchQuery: String = "", cache: OCRDerivedCache = .shared, sourceStore: HistoryStore? = nil) {
        self.record = record; self.cache = cache; self.sourceStore = sourceStore
        let panel = OCRPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "图片与识别文字"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 680, height: 520)
        super.init(window: panel)
        panel.delegate = self
        query.stringValue = searchQuery; canvas.query = searchQuery
        buildInterface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(relativeTo parent: NSWindow?) {
        guard !presented, let window else { return }
        presented = true
        if let frame = (parent?.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        parent?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        rotate.isEnabled = onRotate != nil
        startRecognition(force: false)
    }
    func dismiss() {
        guard presented else { return }
        presented = false; cancelWork()
        result = nil; editor.string = ""; canvas.regions = []; canvas.image = nil
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil) }
        onDismiss?()
    }
    func windowWillClose(_ notification: Notification) { dismiss() }

    private func buildInterface() {
        guard let window else { return }
        let root = NSView(); window.contentView = root
        let title = NSTextField(labelWithString: record.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        query.placeholderString = "在识别文字中查找"
        query.target = self; query.action = #selector(queryChanged)
        query.sendsSearchStringImmediately = true
        query.setAccessibilityLabel("图片识别文字搜索")
        let header = NSStackView(views: [title, query]); header.spacing = 16
        query.widthAnchor.constraint(equalToConstant: 260).isActive = true
        canvas.setAccessibilityLabel("原图预览，青色为识别区域，黄色为搜索命中")
        regionToggle.state = .on; regionToggle.target = self; regionToggle.action = #selector(toggleRegions)
        fullText.target = self; fullText.action = #selector(toggleFullText)
        retry.target = self; retry.action = #selector(retryRecognition)
        cancel.target = self; cancel.action = #selector(cancelRecognition)
        let controls = NSStackView(views: [regionToggle, fullText, retry, cancel]); controls.spacing = 12
        textScroll.documentView = editor; textScroll.hasVerticalScroller = true; textScroll.borderType = .bezelBorder
        textScroll.isHidden = true
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.font = .systemFont(ofSize: 14); editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 160)
        editor.minSize = NSSize(width: 0, height: 160)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("本机识别全文，可选择复制")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rotate.target = self; rotate.action = #selector(rotateImage)
        extract.target = self; extract.action = #selector(extractText); extract.isEnabled = false
        let close = NSButton(title: "关闭", target: self, action: #selector(closePreview)); close.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [status, rotate, extract, close]); actions.spacing = 10
        let stack = NSStackView(views: [header, controls, canvas, textScroll, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), textScroll.heightAnchor.constraint(equalToConstant: 160),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor), canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
    }

    private func startRecognition(force: Bool) {
        cancelWork(); let current = generation
        result = nil; canvas.regions = []; editor.string = ""; extract.isEnabled = false
        retry.isEnabled = false; cancel.isEnabled = true
        status.stringValue = "正在本机识别…原图保持不变"
        guard let data = OCRDerivedCache.imageData(in: record) else {
            status.stringValue = "这条记录没有可读取的图片。"; retry.isEnabled = true; cancel.isEnabled = false; return
        }
        let cache = self.cache, record = self.record
        work = Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) { try LocalIntelligenceService.decodedImage(in: data) }.value
                guard let self, self.presented, self.generation == current else { return }
                try Task.checkCancellation()
                try OCRDerivedCache.validateSource(record, in: self.sourceStore)
                self.canvas.image = image
                let cached = force ? nil : try await cache.result(for: record, imageData: data)
                let recognized: LocalIntelligenceService.OCRResult
                if let cached { recognized = cached }
                else { recognized = try await self.recognizer.recognizeText(in: data) }
                try Task.checkCancellation()
                guard self.presented, self.generation == current else { return }
                if cached == nil {
                    do { try await cache.store(recognized, for: record, imageData: data, sourceStore: self.sourceStore) }
                    catch OCRDerivedCache.CacheError.sourceChanged { throw OCRDerivedCache.CacheError.sourceChanged }
                    catch { /* A disk cache failure does not hide a valid local recognition result. */ }
                }
                try Task.checkCancellation()
                guard self.presented, self.generation == current else { return }
                try OCRDerivedCache.validateSource(record, in: self.sourceStore)
                self.result = recognized; self.canvas.regions = recognized.regions; self.editor.string = recognized.text
                self.retry.isEnabled = true; self.cancel.isEnabled = false
                self.extract.isEnabled = !recognized.text.isEmpty && self.onExtractText != nil
                self.updateStatus()
            } catch {
                guard let self, self.presented, self.generation == current else { return }
                if case OCRDerivedCache.CacheError.sourceChanged = error {
                    self.result = nil; self.canvas.regions = []; self.canvas.image = nil; self.editor.string = ""
                    self.extract.isEnabled = false; self.rotate.isEnabled = false; self.retry.isEnabled = false
                    self.status.stringValue = error.localizedDescription
                } else {
                    self.status.stringValue = error is CancellationError ? "已取消识别，可重新尝试。" : "识别失败：\(error.localizedDescription)"
                    self.retry.isEnabled = true
                }
                self.cancel.isEnabled = false
            }
        }
    }
    private func cancelWork() { generation &+= 1; work?.cancel(); work = nil; recognizer.cancelRecognition() }
    private func updateStatus() {
        guard let result else { return }
        let matched = result.regions.reduce(0) { $0 + ImagePreviewGeometry.matches(in: $1, query: query.stringValue).count }
        let confidence = result.regions.isEmpty ? 0 : result.regions.reduce(Float(0)) { $0 + $1.confidence } / Float(result.regions.count)
        status.stringValue = result.text.isEmpty ? "未识别到文字 · 可重新识别" : "\(result.regions.count) 个区域 · \(matched) 处命中 · 平均置信度 \(Int(confidence * 100))%"
        status.toolTip = "\(result.engineIdentifier) r\(result.engineRevision)\n\(result.engineVersion)\n语言：\(result.recognitionLanguages.joined(separator: ", "))"
    }
    @objc private func queryChanged() { canvas.query = query.stringValue; updateStatus() }
    @objc private func toggleRegions() { canvas.showsRegions = regionToggle.state == .on }
    @objc private func toggleFullText() { textScroll.isHidden = fullText.state != .on; if !textScroll.isHidden { window?.makeFirstResponder(editor) } }
    @objc private func retryRecognition() { startRecognition(force: true) }
    @objc private func cancelRecognition() {
        cancelWork(); status.stringValue = "已取消识别，可重新尝试。"; retry.isEnabled = true; cancel.isEnabled = false
    }
    @objc private func closePreview() { dismiss() }
    @objc private func rotateImage() { let callback = onRotate; dismiss(); callback?() }
    @objc private func extractText() { guard result?.text.isEmpty == false else { return }; let callback = onExtractText; dismiss(); callback?() }
}
