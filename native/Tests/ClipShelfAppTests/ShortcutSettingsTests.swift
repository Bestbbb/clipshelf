import AppKit
import XCTest
@testable import ClipShelf

@MainActor private final class UnshownShortcutWindow: NSWindow {
    var logicallyVisible = false
    var logicallyKey = false
    override var isVisible: Bool { logicallyVisible }
    override var isKeyWindow: Bool { logicallyKey }
    override func makeKeyAndOrderFront(_ sender: Any?) { logicallyVisible = true; logicallyKey = true }
    override func orderOut(_ sender: Any?) { logicallyVisible = false; logicallyKey = false }
    override func center() {}
}

@MainActor private final class ShortcutSettingsHarness {
    var activations = 0
    let controller: ShortcutSettingsController
    let window: UnshownShortcutWindow
    init() {
        var activate: @MainActor () -> Void = {}
        controller = ShortcutSettingsController(activateApplication: { activate() })
        window = UnshownShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 640),
                                       styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = controller.window?.contentView
        window.delegate = controller
        controller.window = window
        activate = { [weak self] in self?.activations += 1 }
    }
    func views<T: NSView>(_ type: T.Type) -> [T] {
        func walk(_ view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap(walk) }
        return window.contentView.map(walk) ?? []
    }
    func button(_ title: String) throws -> NSButton { try XCTUnwrap(views(NSButton.self).first { $0.title == title }) }
    func message() throws -> String { try XCTUnwrap(views(NSTextField.self).first { $0.accessibilityLabel() == "快捷键设置错误" }).stringValue }
    func invoke(_ name: String) { controller.perform(NSSelectorFromString(name)) }
    func close() { invoke("cancelChanges") }
}

final class ShortcutSettingsTests: XCTestCase {
    enum Failure: Error, LocalizedError { case occupied; var errorDescription: String? { "合成占用错误" } }

    @MainActor func testDraftCancelDoesNotApplyAndReopenUsesCommittedValues() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        var applied = 0
        h.controller.onApply = { _, _ in applied += 1; return .success(()) }
        h.controller.show(configuration: .defaults, alwaysPlainText: true)
        XCTAssertEqual(h.activations, 1)
        let recorder = try XCTUnwrap(h.views(ShortcutRecorderView.self).first)
        recorder.beginRecording()
        XCTAssertTrue(h.controller.captureRegisteredShortcut(ShortcutChord(keyCode: 122, modifiers: .control)))
        XCTAssertNotEqual(h.controller.draft, .defaults)
        XCTAssertTrue(h.controller.draftAlwaysPlainText)
        h.close()
        XCTAssertEqual(applied, 0)
        h.controller.show(configuration: .defaults, alwaysPlainText: false)
        XCTAssertEqual(h.controller.draft, .defaults)
        XCTAssertFalse(h.controller.draftAlwaysPlainText)
        XCTAssertEqual(h.activations, 2)
    }

    @MainActor func testDefaultsPreserveGeneralPlainTextPreferenceAndNeverApply() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        var config = KeyboardShortcutConfiguration.defaults
        config.activation = ShortcutChord(keyCode: 122, modifiers: .control)
        var applied = false
        h.controller.onApply = { _, _ in applied = true; return .success(()) }
        h.controller.show(configuration: config, alwaysPlainText: true)
        h.invoke("restoreDefaults")
        XCTAssertEqual(h.controller.draft, .defaults)
        XCTAssertTrue(h.controller.draftAlwaysPlainText)
        XCTAssertFalse(applied)
    }

    @MainActor func testInlineConflictDisablesSaveAndCorrectionRetainsDraft() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        var probes: [KeyboardShortcutConfiguration] = []
        h.controller.onValidate = { config in probes.append(config); return config.activation.keyCode == 122 ? .failure(Failure.occupied) : .success(()) }
        h.controller.show(configuration: .defaults, alwaysPlainText: false, registrationMessage: "启动时 Stack 未注册")
        XCTAssertEqual(try h.message(), "启动时 Stack 未注册")
        let recorder = try XCTUnwrap(h.views(ShortcutRecorderView.self).first)
        recorder.beginRecording(); _ = h.controller.captureRegisteredShortcut(ShortcutChord(keyCode: 122, modifiers: .control))
        XCTAssertFalse(try h.button("保存").isEnabled)
        XCTAssertEqual(try h.message(), "合成占用错误")
        XCTAssertEqual(h.controller.draft.activation.keyCode, 122)
        recorder.beginRecording(); _ = h.controller.captureRegisteredShortcut(ShortcutChord(keyCode: 120, modifiers: .control))
        XCTAssertTrue(try h.button("保存").isEnabled)
        XCTAssertEqual(try h.message(), "启动时 Stack 未注册")
        XCTAssertEqual(probes.count, 3)
    }

    @MainActor func testApplyFailureKeepsDraftAndWindowThenSuccessCloses() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        h.controller.show(configuration: .defaults, alwaysPlainText: true)
        let recorder = try XCTUnwrap(h.views(ShortcutRecorderView.self).first)
        recorder.beginRecording(); _ = h.controller.captureRegisteredShortcut(ShortcutChord(keyCode: 122, modifiers: .control))
        let draft = h.controller.draft
        h.controller.onApply = { config, plain in
            XCTAssertEqual(config, draft); XCTAssertTrue(plain)
            return .failure(Failure.occupied)
        }
        h.invoke("applyChanges")
        XCTAssertTrue(h.controller.isVisible)
        XCTAssertEqual(h.controller.draft, draft)
        XCTAssertEqual(try h.message(), "合成占用错误")
        h.controller.onApply = { _, _ in .success(()) }
        h.invoke("applyChanges")
        XCTAssertFalse(h.controller.isVisible)
    }

    @MainActor func testCaptureRequiresKeyWindowAndOnlyOneRecorderOwnsInput() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        h.controller.show(configuration: .defaults, alwaysPlainText: false)
        let recorders = h.views(ShortcutRecorderView.self)
        XCTAssertEqual(recorders.count, 4)
        recorders[0].beginRecording(); recorders[1].beginRecording()
        XCTAssertFalse(recorders[0].isRecording); XCTAssertTrue(recorders[1].isRecording)
        h.window.logicallyKey = false
        XCTAssertFalse(h.controller.captureRegisteredShortcut(.init(keyCode: 122, modifiers: .control)))
        h.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(recorders[1].isRecording)
        h.window.logicallyKey = true
        XCTAssertFalse(h.controller.captureRegisteredShortcut(.init(keyCode: 122, modifiers: .control)))
    }

    @MainActor func testTryHidesWithoutLosingDraftAndInputSourceChangeRevalidates() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        var validates = 0, trials = 0
        h.controller.onValidate = { _ in validates += 1; return .success(()) }
        h.controller.show(configuration: .defaults, alwaysPlainText: true)
        let recorder = try XCTUnwrap(h.views(ShortcutRecorderView.self).first)
        recorder.beginRecording(); _ = h.controller.captureRegisteredShortcut(.init(keyCode: 122, modifiers: .control))
        let draft = h.controller.draft
        recorder.beginRecording()
        h.controller.keyboardInputSourceDidChange()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(h.controller.draft, draft)
        XCTAssertEqual(validates, 3)
        h.controller.onTryActivation = { XCTAssertFalse(h.controller.isVisible); trials += 1 }
        h.invoke("tryActivation")
        XCTAssertEqual(trials, 1)
        h.controller.show(configuration: .defaults, alwaysPlainText: false)
        XCTAssertEqual(h.controller.draft, draft)
        XCTAssertTrue(h.controller.draftAlwaysPlainText)
    }

    @MainActor func testControlsLayoutFitsUnshownContentBounds() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        h.controller.show(configuration: .defaults, alwaysPlainText: false)
        let content = try XCTUnwrap(h.window.contentView)
        content.layoutSubtreeIfNeeded()
        for button in h.views(NSButton.self) {
            let rect = button.convert(button.bounds, to: content)
            XCTAssertGreaterThan(rect.width, 0, button.title)
            XCTAssertGreaterThanOrEqual(rect.minX, -1, button.title)
            XCTAssertLessThanOrEqual(rect.maxX, content.bounds.maxX + 1, button.title)
            XCTAssertGreaterThanOrEqual(rect.minY, -1, button.title)
            XCTAssertLessThanOrEqual(rect.maxY, content.bounds.maxY + 1, button.title)
        }
    }
    @MainActor func testSmallWindowKeepsActionsAndErrorsVisibleWhileBodyScrolls() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        h.controller.show(configuration: .defaults, alwaysPlainText: false)
        h.window.setContentSize(NSSize(width: 600, height: 330))
        let content = try XCTUnwrap(h.window.contentView)
        content.layoutSubtreeIfNeeded()
        h.controller.onValidate = { _ in .failure(Failure.occupied) }
        h.controller.keyboardInputSourceDidChange()
        XCTAssertEqual(try h.message(), "合成占用错误")
        for title in ["保存", "取消", "恢复默认", "试用唤起面板"] {
            let button = try h.button(title)
            let frame = button.convert(button.bounds, to: content)
            XCTAssertTrue(content.bounds.contains(frame), title)
        }
        let error = try XCTUnwrap(h.views(NSTextField.self).first { $0.accessibilityLabel() == "快捷键设置错误" })
        XCTAssertTrue(content.bounds.contains(error.convert(error.bounds, to: content)))
        let scroll = try XCTUnwrap(h.views(NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The full fixed-help section remains reachable by scrolling")
    }

    @MainActor func testFocusedRecorderOwnsReturnBeforeDefaultSaveKeyEquivalent() throws {
        let h = ShortcutSettingsHarness(); defer { h.close() }
        var applied = 0
        h.controller.onApply = { _, _ in applied += 1; return .success(()) }
        h.controller.show(configuration: .defaults, alwaysPlainText: false)
        let recorder = try XCTUnwrap(h.views(ShortcutRecorderView.self).first)
        XCTAssertTrue(h.window.makeFirstResponder(recorder))
        func returnEvent() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                            windowNumber: h.window.windowNumber, context: nil, characters: "\r",
                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        XCTAssertTrue(h.window.performKeyEquivalent(with: returnEvent()))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(applied, 0)
        // The next Return is recorded as a draft and validated as reserved; it
        // cannot leak through to Save just because capture ended synchronously.
        XCTAssertTrue(h.window.performKeyEquivalent(with: returnEvent()))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(h.controller.draft.activation.keyCode, 36)
        XCTAssertEqual(applied, 0)
        h.invoke("restoreDefaults")
        XCTAssertTrue(h.window.makeFirstResponder(try h.button("保存")))
        XCTAssertTrue(h.window.performKeyEquivalent(with: returnEvent()))
        XCTAssertEqual(applied, 1)
    }

}
