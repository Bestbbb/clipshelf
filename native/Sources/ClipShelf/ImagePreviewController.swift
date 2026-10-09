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
    var onPrepareEdit: ((ClipboardSelectionReference, @escaping (Result<ClipboardEditSnapshot, Error>) -> Void) -> Void)?
    var onEdit: ((ClipboardEditSnapshot, ClipboardRecord, @escaping (Result<ClipboardSelectionReference, Error>) -> Void) -> Void)?
    var onCommitted: ((ClipboardSelectionReference, ClipboardRecord) -> Void)?
    var onExtractText: ((ClipboardRecord) -> Void)?
    var presentWindow: ((NSWindow, NSWindow?) -> Void)?
    var isContextCurrent: (() -> Bool)?
    var recognizeImage: ((Data) async throws -> LocalIntelligenceService.OCRResult)?
    var rotationConverter: @Sendable (ClipboardRecord) throws -> ClipboardRecord = { try ImageRotationPlan.rotatedRecord($0) }
    private(set) var currentRecord: ClipboardRecord
    private let cache: OCRDerivedCache
    private let sourceStore: HistoryStore?
    private let recognizer = LocalIntelligenceService()
    private let canvas = OCRImageCanvas()
    private let status = NSTextField(labelWithString: "正在读取图片…")
    private let title = NSTextField(labelWithString: "")
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
    private var previewSession = UUID()
    private var rotationOperationID: UUID?
    private var rotationPreparing = false
    private var rotationTask: Task<ClipboardRecord, Error>?
    private var rotationWork: Task<Void, Never>?
    private var preparedRotation: (snapshot: ClipboardEditSnapshot, record: ClipboardRecord)?
    private var rotationMessage: String?
    private var recognitionMessage = "正在读取图片…"
    private var sourceInvalid = false

    init(record: ClipboardRecord, searchQuery: String = "", cache: OCRDerivedCache = .shared, sourceStore: HistoryStore? = nil) {
        self.currentRecord = record; self.cache = cache; self.sourceStore = sourceStore
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
        guard !presented, isContextCurrent?() != false, let window else { return }
        presented = true; previewSession = UUID(); sourceInvalid = false
        if let presentWindow { presentWindow(window, parent) }
        else {
            if let frame = (parent?.screen ?? NSScreen.main)?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
            }
            parent?.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        updateActions()
        startRecognition(force: false)
    }
    func dismiss() {
        guard presented else { return }
        presented = false; previewSession = UUID(); cancelWork(); cancelRotation()
        result = nil; editor.string = ""; canvas.regions = []; canvas.image = nil
        updateActions()
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil) }
        onDismiss?()
    }
    func windowWillClose(_ notification: Notification) { dismiss() }

    private func buildInterface() {
        guard let window else { return }
        let root = NSView(); window.contentView = root
        title.stringValue = currentRecord.title
        title.setAccessibilityLabel("图片标题")
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
        status.setAccessibilityLabel("图片预览状态")
        status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        setRecognitionStatus("正在本机识别…原图保持不变")
        guard let data = OCRDerivedCache.imageData(in: currentRecord) else {
            setRecognitionStatus("这条记录没有可读取的图片。"); retry.isEnabled = true; cancel.isEnabled = false; return
        }
        let cache = self.cache, record = self.currentRecord
        work = Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) { try LocalIntelligenceService.decodedImage(in: data) }.value
                guard let self, self.presented, self.isContextCurrent?() != false, self.generation == current else { return }
                try Task.checkCancellation()
                try OCRDerivedCache.validateSource(record, in: self.sourceStore)
                self.canvas.image = image
                let cached = force ? nil : try await cache.result(for: record, imageData: data)
                let recognized: LocalIntelligenceService.OCRResult
                if let cached { recognized = cached }
                else if let recognizeImage = self.recognizeImage { recognized = try await recognizeImage(data) }
                else { recognized = try await self.recognizer.recognizeText(in: data) }
                try Task.checkCancellation()
                guard self.presented, self.isContextCurrent?() != false, self.generation == current else { return }
                if cached == nil {
                    do { try await cache.store(recognized, for: record, imageData: data, sourceStore: self.sourceStore) }
                    catch OCRDerivedCache.CacheError.sourceChanged { throw OCRDerivedCache.CacheError.sourceChanged }
                    catch { /* A disk cache failure does not hide a valid local recognition result. */ }
                }
                try Task.checkCancellation()
                guard self.presented, self.isContextCurrent?() != false, self.generation == current else { return }
                try OCRDerivedCache.validateSource(record, in: self.sourceStore)
                self.result = recognized; self.canvas.regions = recognized.regions; self.editor.string = recognized.text
                self.retry.isEnabled = true; self.cancel.isEnabled = false
                self.updateActions(); self.updateStatus()
            } catch {
                guard let self, self.presented, self.isContextCurrent?() != false, self.generation == current else { return }
                if case OCRDerivedCache.CacheError.sourceChanged = error {
                    self.result = nil; self.canvas.regions = []; self.canvas.image = nil; self.editor.string = ""
                    self.sourceInvalid = true; self.updateActions(); self.retry.isEnabled = false
                    self.setRecognitionStatus(error.localizedDescription)
                } else {
                    self.setRecognitionStatus(error is CancellationError ? "已取消识别，可重新尝试。" : "识别失败：\(error.localizedDescription)")
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
        setRecognitionStatus(result.text.isEmpty ? "未识别到文字 · 可重新识别" : "\(result.regions.count) 个区域 · \(matched) 处命中 · 平均置信度 \(Int(confidence * 100))%")
        status.toolTip = "\(result.engineIdentifier) r\(result.engineRevision)\n\(result.engineVersion)\n语言：\(result.recognitionLanguages.joined(separator: ", "))"
    }
    @objc private func queryChanged() { canvas.query = query.stringValue; updateStatus() }
    @objc private func toggleRegions() { canvas.showsRegions = regionToggle.state == .on }
    @objc private func toggleFullText() { textScroll.isHidden = fullText.state != .on; if !textScroll.isHidden { window?.makeFirstResponder(editor) } }
    @objc private func retryRecognition() { guard presented, !sourceInvalid else { return }; startRecognition(force: true) }
    @objc private func cancelRecognition() {
        cancelWork(); setRecognitionStatus("已取消识别，可重新尝试。"); retry.isEnabled = true; cancel.isEnabled = false
    }
    @objc private func closePreview() { dismiss() }
    @objc private func rotateImage() {
        guard presented, isContextCurrent?() != false, !sourceInvalid, rotationOperationID == nil, let onPrepareEdit, onEdit != nil else { return }
        let operation = UUID(), session = previewSession
        let reference = ClipboardSelectionReference(id: currentRecord.id, revision: currentRecord.revision)
        rotationOperationID = operation
        if let preparedRotation {
            rotationMessage = "正在重试保存旋转…"; renderStatus(); updateActions()
            submitRotation(preparedRotation, operation: operation, session: session, reference: reference)
            return
        }
        rotationMessage = "正在检查旋转权限…"; rotationPreparing = true; renderStatus(); updateActions()
        onPrepareEdit(reference) { [weak self] response in
            guard let self, self.rotationPreparing, self.rotationIsCurrent(operation, session: session, reference: reference) else { return }
            self.rotationPreparing = false
            switch response {
            case .failure(let error): self.rotationFailed(error, stage: "无法开始旋转")
            case .success(let snapshot):
                guard snapshot.record.id == reference.id, snapshot.record.revision == reference.revision,
                      snapshot.record.hasSameContents(as: self.currentRecord) else {
                    self.rotationFailed(OCRDerivedCache.CacheError.sourceChanged, stage: "无法开始旋转"); return
                }
                self.convertRotation(snapshot, operation: operation, session: session, reference: reference)
            }
        }
    }

    private func convertRotation(_ snapshot: ClipboardEditSnapshot, operation: UUID, session: UUID, reference: ClipboardSelectionReference) {
        rotationMessage = "正在准备旋转图片…原图保持不变"; renderStatus()
        let converter = rotationConverter
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let rotated = try converter(snapshot.record)
            try Task.checkCancellation()
            return rotated
        }
        rotationTask = task
        rotationWork = Task { [weak self] in
            do {
                let converted = try await task.value
                try Task.checkCancellation()
                guard let self, self.rotationIsCurrent(operation, session: session, reference: reference) else { return }
                self.rotationTask = nil; self.rotationWork = nil
                guard converted.id == snapshot.record.id, converted.revision == snapshot.record.revision else {
                    self.rotationFailed(OCRDerivedCache.CacheError.sourceChanged, stage: "旋转结果不匹配"); return
                }
                let prepared = (snapshot: snapshot, record: converted)
                self.preparedRotation = prepared
                self.submitRotation(prepared, operation: operation, session: session, reference: reference)
            } catch {
                guard let self, self.rotationIsCurrent(operation, session: session, reference: reference) else { return }
                self.rotationTask = nil; self.rotationWork = nil
                self.rotationFailed(error, stage: "旋转失败")
            }
        }
    }

    private func submitRotation(_ prepared: (snapshot: ClipboardEditSnapshot, record: ClipboardRecord), operation: UUID,
                                session: UUID, reference: ClipboardSelectionReference) {
        guard rotationIsCurrent(operation, session: session, reference: reference), let onEdit else { return }
        rotationMessage = "正在保存旋转…关闭预览不会撤回已提交的保存。"; renderStatus(); updateActions()
        onEdit(prepared.snapshot, prepared.record) { [weak self] response in
            guard let self, self.rotationIsCurrent(operation, session: session, reference: reference) else { return }
            switch response {
            case .failure(let error): self.rotationFailed(error, stage: "旋转保存失败")
            case .success(let committed):
                guard committed.id == reference.id, committed.revision > reference.revision else {
                    self.rotationFailed(OCRDerivedCache.CacheError.sourceChanged, stage: "保存回执不匹配"); return
                }
                self.cancelWork()
                var saved = prepared.record; saved.revision = committed.revision
                self.currentRecord = saved; self.title.stringValue = saved.title
                self.preparedRotation = nil; self.rotationOperationID = nil; self.rotationMessage = nil
                self.sourceInvalid = false; self.canvas.image = nil
                self.updateActions()
                self.onCommitted?(reference, saved)
                // The app completes its old-cache cleanup before the commit callback.
                // Never remove here: that could erase a newer background OCR result.
                guard self.presented, self.isContextCurrent?() != false, self.previewSession == session,
                      self.currentRecord.id == saved.id, self.currentRecord.revision == saved.revision else { return }
                self.startRecognition(force: false)
            }
        }
    }

    private func rotationIsCurrent(_ operation: UUID, session: UUID, reference: ClipboardSelectionReference) -> Bool {
        presented && isContextCurrent?() != false && previewSession == session && rotationOperationID == operation
            && currentRecord.id == reference.id && currentRecord.revision == reference.revision
    }
    private func rotationFailed(_ error: Error, stage: String) {
        rotationOperationID = nil
        rotationMessage = "\(stage)：\(error.localizedDescription) 原图保留；可重试，条目、权限或账号变化时请重新打开。"
        renderStatus(); updateActions()
    }
    private func cancelRotation() {
        rotationOperationID = nil; rotationPreparing = false; rotationTask?.cancel(); rotationTask = nil
        rotationWork?.cancel(); rotationWork = nil; preparedRotation = nil; rotationMessage = nil
    }
    private func updateActions() {
        rotate.isEnabled = presented && !sourceInvalid && rotationOperationID == nil && onPrepareEdit != nil && onEdit != nil
        rotate.title = preparedRotation == nil ? "向左旋转" : "重试保存旋转"
        extract.isEnabled = presented && rotationOperationID == nil && result?.text.isEmpty == false && onExtractText != nil
    }
    private func setRecognitionStatus(_ text: String) { recognitionMessage = text; renderStatus() }
    private func renderStatus() { status.stringValue = rotationMessage ?? recognitionMessage }
    @objc private func extractText() {
        guard presented, isContextCurrent?() != false, rotationOperationID == nil, result?.text.isEmpty == false else { return }
        let callback = onExtractText, record = currentRecord
        dismiss(); callback?(record)
    }
}
