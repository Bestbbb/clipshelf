import AppKit
import ClipShelfCore
import ClipShelfLocalization
import PDFKit
import Quartz
import UniformTypeIdentifiers

private final class MultipartPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A preview never follows a URL or opens an embedded attachment. The parent
/// remains responsible for actions on the complete original clipboard record.
private final class MultipartReadOnlyTextView: NSTextView {
    override func clicked(onLink link: Any, at charIndex: Int) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func quickLookPreviewableItems(inRanges ranges: [NSValue]) -> [any QLPreviewItem] { [] }
}

private final class MultipartReadOnlyPDFView: PDFView {
    override func perform(_ action: PDFAction) {
        if action is PDFActionGoTo { super.perform(action) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// Every selector row refers to an original part index, including unsupported
/// objects. Only the selected part is decoded, and at most one decoder runs at a
/// time. A cancelled native decoder may finish, but cannot publish stale content.
@MainActor
final class MultipartPreviewController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    typealias Loader = @Sendable (ClipboardRecord, Int) async throws -> ClipboardPartPreviewPlan

    var onEdit: ((Int) -> Void)? { didSet { updateActions() } }
    var onFileReferences: (() -> Void)? { didSet { updateActions() } }
    var onImageTools: (() -> Void)? { didSet { updateActions() } }
    var onDismiss: (() -> Void)?
    var isContextCurrent: (() -> Bool)?
    var presentWindow: ((NSWindow, NSWindow?) -> Void)?
    private(set) var selectedPartIndex: Int
    private(set) var displayedPlan: ClipboardPartPreviewPlan?
    private(set) var isLoading = false

    private let record: ClipboardRecord
    private let loader: Loader
    private let selector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previewHost = NSView()
    private let textView = MultipartReadOnlyTextView(frame: .zero)
    private let textScroll = NSScrollView()
    private let imageView = NSImageView()
    private let pdfView = MultipartReadOnlyPDFView()
    private let metadata = MultipartReadOnlyTextView(frame: .zero)
    private let metadataScroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let edit = NSButton(title: L10n.text("编辑"), target: nil, action: nil)
    private let files = NSButton(title: L10n.text("文件与位置…"), target: nil, action: nil)
    private let imageTools = NSButton(title: L10n.text("图片与识别文字"), target: nil, action: nil)
    private let previousPage = NSButton(title: L10n.text("上一页"), target: nil, action: nil)
    private let nextPage = NSButton(title: L10n.text("下一页"), target: nil, action: nil)
    private let zoomOut = NSButton(title: L10n.text("缩小"), target: nil, action: nil)
    private let zoomIn = NSButton(title: L10n.text("放大"), target: nil, action: nil)
    private let pageNumber = NSTextField(labelWithString: "")
    private var pdfControls: NSStackView!
    private var pageObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var presented = false
    private var session = UUID()
    private var selectedIsEditable = false
    private var selectedIsFile = false
    private var selectedHasImageTools = false
    private struct Request: Equatable {
        let id = UUID()
        let session: UUID
        let partIndex: Int
    }
    private var selectionRequest: Request?
    private var pendingRequest: Request?
    private var runningRequest: Request?
    private var loadTask: Task<Void, Never>?

    init(record: ClipboardRecord, initialPartIndex: Int = 0, window: NSPanel? = nil, loader: Loader? = nil) {
        self.record = record
        selectedPartIndex = record.parts.indices.contains(initialPartIndex) ? initialPartIndex : 0
        self.loader = loader ?? { record, index in
            let task = Task.detached(priority: .userInitiated) {
                try ClipboardPartPreviewPlan.make(original: record, partIndex: index)
            }
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        let panel = window ?? MultipartPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.text("预览剪贴板内容")
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 620, height: 480)
        super.init(window: panel)
        panel.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(relativeTo parent: NSWindow?) {
        guard !presented, isContextCurrent?() != false, let window else { return }
        presented = true; session = UUID()
        if let presentWindow { presentWindow(window, parent) }
        else {
            if let frame = (parent?.screen ?? NSScreen.main)?.visibleFrame {
                let size = NSSize(width: min(window.frame.width, frame.width), height: min(window.frame.height, frame.height))
                window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                       width: size.width, height: size.height), display: false)
            }
            parent?.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        // Presentation may synchronously dismiss or replace this controller.
        guard checkContext() else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
        window.makeFirstResponder(selector)
        selectPart(at: selectedPartIndex)
    }

    func dismiss() {
        guard presented else { return }
        presented = false; session = UUID(); selectionRequest = nil; pendingRequest = nil
        loadTask?.cancel()
        clearContent(); metadata.string = ""; status.stringValue = ""
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil) }
        updateActions()
        onDismiss?()
    }

    /// Parent view/scope invalidation removes the child without awaiting a decoder.
    func invalidateContext() { dismiss() }
    func windowWillClose(_ notification: Notification) { dismiss() }

    func ownsWindow(_ candidate: NSWindow?) -> Bool {
        guard presented, let candidate else { return false }
        var next: NSWindow? = candidate
        while let current = next {
            if current === window { return true }
            next = current.sheetParent ?? current.parent
        }
        return false
    }

    func contains(screenPoint: NSPoint) -> Bool {
        presented && window?.isVisible == true && window?.frame.contains(screenPoint) == true
    }

    func selectPart(at index: Int) {
        guard checkContext(), record.parts.indices.contains(index) else { return }
        selectedPartIndex = index; selector.selectItem(at: index)
        let request = Request(session: session, partIndex: index)
        selectionRequest = request; pendingRequest = request
        loadTask?.cancel()
        clearContent(); updateStructuralActions(); showMetadata(for: index)
        isLoading = true; status.stringValue = L10n.text("正在读取条目…")
        updateActions(); startPendingLoad()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard checkContext(), event.type == .keyDown,
              (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        let flags = ShortcutChord.normalizedModifiers(event.modifierFlags)
        if event.keyCode == 53 || (flags == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
            dismiss(); return true
        }
        if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "e" {
            if !event.isARepeat { editSelected() }
            return true
        }
        return false
    }

    @objc func editSelected() {
        guard checkContext(), edit.isEnabled, !isLoading, selectedIsEditable else { return }
        onEdit?(selectedPartIndex)
    }

    @objc func showFileReferences() {
        guard checkContext(), files.isEnabled, !isLoading, selectedIsFile else { return }
        onFileReferences?()
    }

    @objc func showImageTools() {
        guard checkContext(), imageTools.isEnabled, !isLoading, selectedHasImageTools else { return }
        onImageTools?()
    }

    @objc private func changePart(_ sender: NSPopUpButton) { selectPart(at: sender.indexOfSelectedItem) }
    @objc private func closePreview() { dismiss() }

    private func checkContext() -> Bool {
        guard presented else { return false }
        guard isContextCurrent?() != false else { dismiss(); return false }
        return true
    }

    private func startPendingLoad() {
        guard runningRequest == nil, let request = pendingRequest, checkContext(),
              request == selectionRequest, request.session == session else { return }
        pendingRequest = nil; runningRequest = request
        let loader = self.loader, record = self.record
        loadTask = Task { [weak self] in
            let result: Result<ClipboardPartPreviewPlan, Error>
            do {
                try Task.checkCancellation()
                let plan = try await loader(record, request.partIndex)
                try Task.checkCancellation()
                result = .success(plan)
            } catch { result = .failure(error) }
            self?.finishedLoading(result, request: request)
        }
    }

    private func finishedLoading(_ result: Result<ClipboardPartPreviewPlan, Error>, request: Request) {
        guard runningRequest == request else { return }
        runningRequest = nil; loadTask = nil
        guard checkContext() else { return }
        if request == selectionRequest, request.session == session, request.partIndex == selectedPartIndex {
            isLoading = false
            switch result {
            case .success(let plan) where plan.partIndex == selectedPartIndex:
                install(plan)
            default:
                clearContent()
                updateStructuralActions()
                status.stringValue = L10n.text("此对象无法显示预览，可查看原始格式与大小。")
            }
            updateActions()
        }
        // A switch coalesces every intervening selection while a synchronous native
        // parser is finishing. It never launches one decoder per keystroke.
        startPendingLoad()
    }

    private func install(_ plan: ClipboardPartPreviewPlan) {
        clearContent(); updateStructuralActions(); displayedPlan = plan
        status.stringValue = plan.isTruncated ? L10n.text("预览仅显示部分内容；原始内容保持完整。") : L10n.text("只读")
        switch plan.content {
        case .richText(let contents):
            textView.textStorage?.setAttributedString(contents); textScroll.isHidden = false
        case .text(let text):
            showText(text)
        case .htmlSource(let source):
            showText(source, monospaced: true)
            if !plan.isTruncated { status.stringValue = L10n.text("HTML 源码") }
        case .image(let image):
            imageView.image = image; imageView.isHidden = false
        case .pdf(let document):
            pdfView.document = document; pdfView.isHidden = false; pdfControls.isHidden = false
            pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePDFControls() }
            }
            updatePDFControls()
        case .file(let url):
            showText(url.path)
        case .unavailable:
            status.stringValue = L10n.text("此对象无法显示预览，可查看原始格式与大小。")
        }
        if ClipboardPartPreviewPlan.isPotentiallyEditable(original: record, partIndex: selectedPartIndex) {
            selectedIsEditable = (try? ClipboardEditPlan.partRecord(original: record, partIndex: selectedPartIndex)) != nil
        }
    }

    private func clearContent() {
        displayedPlan = nil; isLoading = false; selectedIsEditable = false; selectedIsFile = false; selectedHasImageTools = false
        textView.textStorage?.setAttributedString(NSAttributedString(string: "")); textScroll.isHidden = true
        imageView.image = nil; imageView.isHidden = true
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver); self.pageObserver = nil }
        pdfView.document = nil; pdfView.isHidden = true; pdfControls?.isHidden = true
        pageNumber.stringValue = ""
    }

    private func showText(_ value: String, monospaced: Bool = false) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: [
            .font: monospaced ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ]))
        textScroll.isHidden = false
    }

    private func showMetadata(for index: Int) {
        metadata.string = record.parts[index].representations.map {
            "\($0.typeIdentifier) · \(L10n.fileSize(Int64($0.data.count)))"
        }.joined(separator: "\n")
    }

    private func updateStructuralActions() {
        guard record.parts.indices.contains(selectedPartIndex) else { return }
        selectedIsFile = record.parts[selectedPartIndex].representations.contains { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }
        // Existing repair and image tools must remain reachable even when this
        // bounded preview cannot decode a malformed or oversized representation.
        selectedHasImageTools = record.kind == .image &&
            !record.parts.flatMap(\.representations).contains { ClipboardFileAccess.isFileURLType($0.typeIdentifier) } &&
            record.parts.firstIndex { part in part.representations.contains { UTType($0.typeIdentifier)?.conforms(to: .image) == true } } == selectedPartIndex
    }

    private func updateActions() {
        let current = presented && isContextCurrent?() != false
        selector.isEnabled = current && !record.parts.isEmpty
        edit.isEnabled = current && !isLoading && selectedIsEditable && onEdit != nil
        files.isHidden = !selectedIsFile
        files.isEnabled = current && !isLoading && selectedIsFile && onFileReferences != nil
        imageTools.isHidden = !selectedHasImageTools
        imageTools.isEnabled = current && !isLoading && selectedHasImageTools && onImageTools != nil
    }

    private func updatePDFControls() {
        guard let document = pdfView.document else { return }
        let index = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        pageNumber.stringValue = L10n.text("第 \(index) / \(document.pageCount) 页")
        previousPage.isEnabled = pdfView.canGoToPreviousPage; nextPage.isEnabled = pdfView.canGoToNextPage
        zoomOut.isEnabled = pdfView.canZoomOut; zoomIn.isEnabled = pdfView.canZoomIn
    }

    private func buildInterface() {
        let root = NSView(); window?.contentView = root
        defer { InterfaceLayout.apply(to: root) }
        selector.target = self; selector.action = #selector(changePart(_:))
        selector.setAccessibilityLabel(L10n.text("预览对象")); selector.setAccessibilityIdentifier("preview.part")
        for (index, part) in record.parts.enumerated() {
            let identifier = part.representations.first?.typeIdentifier ?? ""
            let kind = UTType(identifier)?.localizedDescription ?? identifier
            let bytes = part.representations.reduce(Int64(0)) { $0 + Int64($1.data.count) }
            selector.addItem(withTitle: L10n.text("对象 \(index + 1)：\(kind) · \(L10n.fileSize(bytes))"))
        }
        selector.selectItem(at: selectedPartIndex)
        let heading = NSTextField(labelWithString: record.title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold); heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureTextView(textView, scroll: textScroll)
        textView.delegate = self; textView.importsGraphics = false
        textView.setAccessibilityLabel(L10n.text("内容预览")); textView.setAccessibilityIdentifier("preview.contents")
        if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.isEditable = false
        imageView.setAccessibilityLabel(L10n.text("内容预览")); imageView.setAccessibilityIdentifier("preview.image")
        pdfView.autoScales = true; pdfView.displayMode = .singlePageContinuous; pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true; pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.setAccessibilityLabel(L10n.text("只读 PDF 文稿预览")); pdfView.setAccessibilityIdentifier("preview.pdf")
        for view in [textScroll, imageView, pdfView] {
            view.translatesAutoresizingMaskIntoConstraints = false; previewHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: previewHost.topAnchor), view.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor)
            ])
        }
        previousPage.target = pdfView; previousPage.action = #selector(PDFView.goToPreviousPage(_:))
        nextPage.target = pdfView; nextPage.action = #selector(PDFView.goToNextPage(_:))
        zoomOut.target = pdfView; zoomOut.action = #selector(PDFView.zoomOut(_:))
        zoomIn.target = pdfView; zoomIn.action = #selector(PDFView.zoomIn(_:))
        pdfControls = NSStackView(views: [previousPage, nextPage, zoomOut, zoomIn, pageNumber]); pdfControls.spacing = 8
        configureTextView(metadata, scroll: metadataScroll)
        metadata.delegate = self; metadata.isRichText = false; metadata.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metadata.setAccessibilityLabel(L10n.text("原始格式与大小")); metadata.setAccessibilityIdentifier("preview.formats")
        metadataScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        edit.target = self; edit.action = #selector(editSelected)
        files.target = self; files.action = #selector(showFileReferences)
        imageTools.target = self; imageTools.action = #selector(showImageTools)
        let close = NSButton(title: L10n.text("返回列表"), target: self, action: #selector(closePreview))
        close.keyEquivalent = "\u{1b}"
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3
        status.setAccessibilityIdentifier("preview.status")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [status, files, imageTools, edit, close]); actions.spacing = 10
        let stack = NSStackView(views: [heading, selector, previewHost, pdfControls, metadataScroll, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor), selector.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewHost.widthAnchor.constraint(equalTo: stack.widthAnchor), previewHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            metadataScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        clearContent(); updateActions()
    }

    private func configureTextView(_ text: NSTextView, scroll: NSScrollView) {
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.allowsUndo = false
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticDataDetectionEnabled = false
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.frame = NSRect(x: 0, y: 0, width: 740, height: 160)
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 740, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
    }

    // Implement attachment delegation to suppress AppKit's default external open
    // and file drag behavior while retaining native embedded attachment rendering.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }
    func textView(_ textView: NSTextView, doubleClickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {}
    func textView(_ view: NSTextView, draggedCell cell: any NSTextAttachmentCellProtocol, in rect: NSRect, event: NSEvent, at charIndex: Int) {}
    func textView(_ textView: NSTextView, urlForContentsOf textAttachment: NSTextAttachment, at charIndex: Int) -> URL? { nil }
}
