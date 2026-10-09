import AppKit
import ClipShelfCore
import UniformTypeIdentifiers

@MainActor
final class SystemIntegrationController: NSObject {
    var onImport: ((ClipboardRecord) throws -> Void)?
    var onStatus: ((String) -> Void)?
    var publications: OwnedFilePublicationCoordinator?
    private var picker: NSSharingServicePicker?
    private var cameraWindow: NSWindow?

    func registerServices() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc func addToClipShelf(_ pasteboard: NSPasteboard, userData: String?, error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            guard let record = try ClipboardCodec.record(from: pasteboard, sourceApp: "系统服务", sourceBundleID: nil) else {
                errorPointer.pointee = "所选内容不可用或被标记为机密。"; return
            }
            guard let onImport else { errorPointer.pointee = "ClipShelf 尚未就绪。"; return }
            try onImport(record)
            onStatus?("已将所选内容保存到 ClipShelf。")
        } catch { errorPointer.pointee = "内容未能保存，现有历史未改变。" }
    }

    func share(_ record: ClipboardRecord, from view: NSView) throws {
        let values = try prepareSharingItems(record)
        picker = NSSharingServicePicker(items: values)
        picker?.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }

    func prepareSharingItems(_ record: ClipboardRecord) throws -> [Any] {
        let lease = record.kind == .file ? try publications?.retain([record]) : nil
        let values: [Any]
        if record.kind == .image, let image = Self.imageData(record).flatMap(NSImage.init(data:)) {
            values = [image]
        } else if record.kind == .file {
            values = try ClipboardCodec.items(for: [record], plainText: false).compactMap { item -> URL? in
                guard let path = item.string(forType: .fileURL) else { return nil }
                return URL(string: path)
            }
        } else if record.kind == .link, let url = URL(string: record.text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            values = [url]
        } else { values = [record.text] }
        guard !values.isEmpty else { throw ClipboardCodecError.noContent }
        // Sharing-service completion does not confirm that its destination has
        // finished reading these URLs. Keep publication roots after the picker.
        if let lease { _ = try publications?.publish(lease: lease, purpose: .sharing) }
        return values
    }

    /// Compatibility entry point for callers exporting exactly one image part.
    static func exportImage(_ record: ClipboardRecord, directory: URL? = nil, now: Date = Date()) throws -> URL {
        let prepared = try ImageFileOutput.prepare([record])
        guard prepared.imageCount == 1 else { throw ClipboardCodecError.noContent }
        return try prepared.exportReceipt(directory: directory, now: now).fileURLs[0]
    }

    static func imageData(_ record: ClipboardRecord) -> Data? {
        record.parts.flatMap(\.representations).first { value in
            UTType(value.typeIdentifier)?.conforms(to: .image) == true
        }?.data
    }

    func presentCameraImport() {
        if let cameraWindow { cameraWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = ContinuityImportView(frame: NSRect(x: 0, y: 0, width: 510, height: 210))
        view.onImport = { [weak self] record in
            guard let self, let onImport = self.onImport else { return false }
            do { try onImport(record); self.onStatus?("已保存连续互通导入的内容。"); return true }
            catch { self.onStatus?("导入失败，现有历史保留。"); return false }
        }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "从 iPhone 或 iPad 导入"
        window.isReleasedWhenClosed = false; window.contentView = view
        cameraWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ContinuityImportView: NSView, @preconcurrency NSServicesMenuRequestor {
    var onImport: ((ClipboardRecord) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(wrappingLabelWithString: "在这里点按右键，选择系统提供的“从 iPhone 或 iPad 导入”，拍摄照片或扫描文稿。\n\n设备需满足 Apple 连续互通条件；没有可用设备时，系统不会显示导入选项。取消扫描不会产生记录。")
        label.frame = bounds.insetBy(dx: 28, dy: 38); label.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 15); label.isSelectable = false
        addSubview(label)
        setAccessibilityLabel("连续互通导入区域")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) || returnType == .pdf { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let record = try? ClipboardCodec.record(from: pasteboard, sourceApp: "连续互通相机", sourceBundleID: nil) else { return false }
        return onImport?(record) ?? false
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return NSMenu(title: "导入")
    }
}
