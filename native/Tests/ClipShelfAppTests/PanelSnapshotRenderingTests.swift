import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

/// Renders the shelf offscreen for visual review. Runs only when
/// CLIPSHELF_SNAPSHOT_DIR is set; it never orders a window onto the desktop.
@MainActor final class PanelSnapshotRenderingTests: XCTestCase {
    func testRenderShelfSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["CLIPSHELF_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set CLIPSHELF_SNAPSHOT_DIR to render shelf snapshots.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for compact in [false, true] {
                let panel = ClipboardPanelController()
                let size = NSSize(width: 1180, height: compact ? 240 : 330)
                let window = UnshownTestPanel(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.contentView = panel.window?.contentView
                window.delegate = panel
                panel.window = window
                window.appearance = NSAppearance(named: appearance)
                panel.setPasteDestination(name: "TextEdit", available: true)
                panel.show(records: Self.records, status: nil)
                window.setFrame(NSRect(origin: .zero, size: size), display: false)
                guard let view = window.contentView else { return XCTFail("missing content") }
                view.appearance = NSAppearance(named: appearance)
                for _ in 0..<3 {
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                }
                let url = output.appendingPathComponent("shelf-\(name)\(compact ? "-compact" : "").png")
                try Self.render(view, appearance: NSAppearance(named: appearance)!, to: url)
                panel.dismiss()
            }
        }
    }

    func testRenderStatusBarIcon() throws {
        guard let directory = ProcessInfo.processInfo.environment["CLIPSHELF_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set CLIPSHELF_SNAPSHOT_DIR to render shelf snapshots.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let icon = StatusBarIcon.image(accessibilityDescription: "ClipShelf")
        let scale: CGFloat = 8, side: CGFloat = 18
        let sheet = NSImage(size: NSSize(width: side * scale * 2 + 30, height: side * scale + 20), flipped: false) { _ in
            for (index, (background, glyph)) in [(NSColor(white: 0.92, alpha: 1), NSColor.black),
                                                 (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
                let frame = NSRect(x: 10 + CGFloat(index) * (side * scale + 10), y: 10, width: side * scale, height: side * scale)
                background.setFill(); frame.fill()
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect); glyph.set(); rect.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: frame)
            }
            return true
        }
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("status-bar-icon.png"))
    }

    private static func render(_ view: NSView, appearance: NSAppearance, to url: URL) throws {
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        // Stand-in for the desktop behind the translucent shelf.
        let backdrop = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? CGColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1) : CGColor(srgbRed: 0.86, green: 0.88, blue: 0.91, alpha: 1)
        context.setFillColor(backdrop); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        appearance.performAsCurrentDrawingAppearance {
            view.displayIfNeeded()
            view.layer?.render(in: context)
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static var records: [ClipboardRecord] {
        let now = Date()
        var result = [
            ClipboardRecord(text: "把复制的内容，放回你的工作流。\n\n唤起、找到、粘贴，然后继续。", sourceApp: "备忘录",
                            sourceBundleID: "com.apple.Notes", copiedAt: now),
            ClipboardRecord(text: "https://github.com/Bestbbb/clipshelf", sourceApp: "Safari",
                            sourceBundleID: "com.apple.Safari", copiedAt: now.addingTimeInterval(-120)),
            ClipboardRecord(text: "struct ClipboardItem: Identifiable {\n    let id: UUID\n    let content: String\n    var pinned = false\n}",
                            sourceApp: "Xcode", sourceBundleID: "com.apple.dt.Xcode", copiedAt: now.addingTimeInterval(-360)),
            ClipboardRecord(text: "#457B9D", sourceApp: "设计稿", copiedAt: now.addingTimeInterval(-900)),
            ClipboardRecord(text: "会议笔记\n• 先把跨 App 的焦点恢复做好\n• 保持中文输入和键盘操作流畅\n• 用真实结果验证粘贴",
                            sourceApp: "TextEdit", sourceBundleID: "com.apple.TextEdit", copiedAt: now.addingTimeInterval(-1600)),
        ]
        let image = NSImage(size: NSSize(width: 640, height: 400))
        image.lockFocus()
        NSColor(calibratedRed: 0.13, green: 0.29, blue: 0.35, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor(calibratedRed: 0.82, green: 0.94, blue: 0.72, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 42, y: 44, width: 556, height: 312), xRadius: 24, yRadius: 24).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            result.append(ClipboardRecord(text: "图片 640 × 400", sourceApp: "预览", sourceBundleID: "com.apple.Preview",
                copiedAt: now.addingTimeInterval(-1800),
                parts: [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.png", data: png)])]))
        }
        result.append(ClipboardRecord(text: "swift test --filter PanelSnapshotRenderingTests", sourceApp: "终端",
                                      sourceBundleID: "com.apple.Terminal", copiedAt: now.addingTimeInterval(-2400)))
        let fileURL = URL(fileURLWithPath: "/Users/Shared/季度报告 Q3.pdf")
        result.append(ClipboardRecord(text: fileURL.path, sourceApp: "访达", sourceBundleID: "com.apple.finder",
            copiedAt: now.addingTimeInterval(-3000), parts: [ClipboardPart(representations: [
                ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(fileURL.absoluteString.utf8))])]))
        let snapshotKinds = ProcessInfo.processInfo.environment["CLIPSHELF_SNAPSHOT_KINDS"]
        // Interleave kinds so the first visible cards cover text, image, code, link and colour.
        let order = snapshotKinds == "more" ? [7, 1, 6, 4, 0] : [0, 5, 2, 1, 3, 4, 6]
        return order.compactMap { $0 < result.count ? result[$0] : nil }
    }
}
