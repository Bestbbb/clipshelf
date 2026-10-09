import AppKit
import ApplicationServices
import ClipShelfCore

@MainActor
final class PasteCoordinator {
    struct Target {
        let application: NSRunningApplication
        let window: AXUIElement?
        let focusedElement: AXUIElement?
    }

    var onClipboardWrite: (() -> Void)?
    var onResult: ((String) -> Void)?
    private var attempt: UUID?
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var hasPermission: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func captureTarget() -> Target? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        return Target(application: application,
                      window: Self.attribute(axApp, kAXFocusedWindowAttribute),
                      focusedElement: Self.attribute(axApp, kAXFocusedUIElementAttribute))
    }

    @discardableResult
    func copy(_ record: ClipboardRecord, plainText: Bool = false) -> Bool {
        copy([record], plainText: plainText)
    }

    @discardableResult
    func copy(_ records: [ClipboardRecord], plainText: Bool = false) -> Bool {
        let items: [NSPasteboardItem]
        do { items = try ClipboardCodec.items(for: records, plainText: plainText) }
        catch { onResult?(error.localizedDescription); return false }
        pasteboard.clearContents()
        let success = pasteboard.writeObjects(items)
        onClipboardWrite?()
        if !success { onResult?("无法写入系统剪贴板，请重试。") }
        return success
    }

    func paste(_ record: ClipboardRecord, plainText: Bool, target: Target?, dismiss: () -> Void) {
        paste([record], plainText: plainText, target: target, dismiss: dismiss)
    }

    func paste(_ records: [ClipboardRecord], plainText: Bool, target: Target?, dismiss: () -> Void,
               onCopied: (() -> Void)? = nil, onDispatched: (() -> Void)? = nil) {
        guard attempt == nil else { return }
        guard copy(records, plainText: plainText) else { return }
        onCopied?()
        let writtenChangeCount = pasteboard.changeCount
        dismiss()
        guard hasPermission, let target, !target.application.isTerminated, target.window != nil else {
            onResult?("内容已复制，请切回目标应用按 ⌘V。")
            return
        }
        // A nonactivating panel normally leaves the intended application in front.
        // If the user selected another app, never force a paste into the stale target.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontPID == target.application.processIdentifier || frontPID == ProcessInfo.processInfo.processIdentifier else {
            onResult?("目标已改变；内容已复制，请手动粘贴。")
            return
        }
        guard target.application.activate(options: []) else {
            onResult?("未能恢复目标应用；内容已复制。")
            return
        }
        if let window = target.window {
            guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
                onResult?("原窗口已不可用；内容已复制，请手动粘贴。")
                return
            }
        }
        if let focused = target.focusedElement {
            _ = AXUIElementSetAttributeValue(focused, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        let identifier = UUID()
        attempt = identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.attempt == identifier { self.attempt = nil } }
            let deadline = Date().addingTimeInterval(0.9)
            while Date() < deadline {
                guard self.attempt == identifier, self.hasPermission, !target.application.isTerminated else { return }
                guard self.pasteboard.changeCount == writtenChangeCount else {
                    self.onResult?("剪贴板已被新的复制替换，本次自动粘贴已取消。")
                    return
                }
                let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if currentPID != target.application.processIdentifier && currentPID != ProcessInfo.processInfo.processIdentifier {
                    self.onResult?("目标已改变；内容已复制，请手动粘贴。")
                    return
                }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                let held = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
                if currentPID == target.application.processIdentifier && held.isEmpty {
                    if let original = target.window {
                        let app = AXUIElementCreateApplication(target.application.processIdentifier)
                        guard let current = Self.attribute(app, kAXFocusedWindowAttribute), CFEqual(original, current) else {
                            self.onResult?("原窗口焦点未恢复；内容已复制。")
                            return
                        }
                        if let originalField = target.focusedElement {
                            guard let currentField = Self.attribute(app, kAXFocusedUIElementAttribute), CFEqual(originalField, currentField) else {
                                self.onResult?("原输入位置未恢复；内容已复制，请手动粘贴。")
                                return
                            }
                        }
                    }
                    guard let source = CGEventSource(stateID: .hidSystemState),
                          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                        self.onResult?("无法创建粘贴按键；内容已复制。")
                        return
                    }
                    down.flags = .maskCommand
                    up.flags = .maskCommand
                    down.setIntegerValueField(.eventSourceUserData, value: StackKeyMonitor.syntheticEventTag)
                    up.setIntegerValueField(.eventSourceUserData, value: StackKeyMonitor.syntheticEventTag)
                    guard self.pasteboard.changeCount == writtenChangeCount else {
                        self.onResult?("剪贴板已改变，本次自动粘贴已取消。")
                        return
                    }
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                    onDispatched?()
                    self.onResult?("已发出粘贴操作。")
                    return
                }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            self.onResult?("目标或修饰键尚未就绪；内容已复制，请手动粘贴。")
        }
    }

    func cancel() { attempt = nil }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
