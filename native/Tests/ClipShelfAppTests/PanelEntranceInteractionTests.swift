import AppKit
import XCTest
import ClipShelfCore
@testable import ClipShelf

@MainActor private final class EntranceAnimation: PanelPresentationAnimation {
    let progress: (CGFloat) -> Void
    let completion: () -> Void
    var cancellations = 0
    init(progress: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.progress = progress; self.completion = completion
    }
    func start() {}
    func cancel() { cancellations += 1 }
}

@MainActor private final class EntranceHarness {
    var animations: [EntranceAnimation] = []
    var visibleFrame = NSRect(x: 0, y: 30, width: 1440, height: 870)
    var requests: [(PanelPageRequest, (Result<PanelHistoryPage, Error>) -> Void)] = []
    var dismissals = 0
    lazy var motion = PanelPresentationMotion(reduceMotion: { false }, notificationCenter: NotificationCenter(),
        makeAnimation: { [unowned self] _, progress, completion in
            let animation = EntranceAnimation(progress: progress, completion: completion)
            animations.append(animation); return animation
        })
    lazy var panel: ClipboardPanelController = {
        let panel = ClipboardPanelController(presentationMotion: motion)
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                     styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
        panel.resolveVisibleScreenFrame = { [unowned self] _ in visibleFrame }
        panel.onDismiss = { [unowned self] in dismissals += 1 }
        return panel
    }()

    func find<T: NSView>(_ type: T.Type, in root: NSView? = nil) throws -> T {
        func walk(_ view: NSView) -> T? { (view as? T) ?? view.subviews.lazy.compactMap(walk).first }
        return try XCTUnwrap((root ?? panel.window?.contentView).flatMap(walk))
    }

    @discardableResult func key(_ code: UInt16) -> Bool {
        let value = code == 36 ? "\r" : "\u{1b}"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: panel.window!.windowNumber, context: nil, characters: value,
            charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!
        return panel.handleKey(event)
    }

    func close() { panel.perform(NSSelectorFromString("discardDetail")); panel.dismiss() }
}

@MainActor final class PanelEntranceInteractionTests: XCTestCase {
    func testSearchAndEscapeWorkBeforeEntranceOrFirstPageCompletes() throws {
        let h = EntranceHarness(); defer { h.close() }
        h.panel.onPageRequest = { [unowned h] request, reply in h.requests.append((request, reply)) }
        h.panel.show(metadata: [])
        let animation = try XCTUnwrap(h.animations.first)
        XCTAssertTrue(h.motion.isAnimating)
        let search = try h.find(NSSearchField.self)
        XCTAssertTrue(h.panel.window?.firstResponder === search || search.currentEditor() === h.panel.window?.firstResponder)
        search.stringValue = "synthetic entrance search"
        h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertEqual(h.requests.last?.0.query.text, search.stringValue)
        XCTAssertTrue(h.key(53))
        XCTAssertEqual(search.stringValue, "", "First Escape keeps the existing clear-search contract")
        XCTAssertTrue(h.panel.isVisible)
        XCTAssertTrue(h.key(53))
        XCTAssertFalse(h.panel.isVisible)
        XCTAssertEqual(h.dismissals, 1)
        XCTAssertEqual(animation.cancellations, 1)
        h.requests[1].1(.success(.init(records: [], offset: 0, hasMore: false, focusID: nil)))
        animation.progress(0.8); animation.completion()
        XCTAssertFalse(h.panel.isVisible)
        XCTAssertEqual(h.dismissals, 1)
        XCTAssertEqual(h.panel.window?.alphaValue, 1)
    }

    func testPasteDuringEntranceHidesSynchronouslyWithoutWaitingForAnimation() throws {
        let h = EntranceHarness(); defer { h.close() }
        let record = ClipboardRecord(text: "synthetic entrance paste")
        var outputs = 0
        h.panel.resolveOutputSelection = { _, reply in reply(.success([record])) }
        h.panel.onPaste = { [unowned h] value, _ in
            XCTAssertEqual(value.id, record.id)
            h.panel.dismiss()
            XCTAssertFalse(h.panel.isVisible, "The paste callback can immediately continue target restoration")
            outputs += 1
        }
        h.panel.show(records: [record])
        let animation = try XCTUnwrap(h.animations.first)
        XCTAssertTrue(h.motion.isAnimating)
        XCTAssertTrue(h.key(36))
        XCTAssertEqual(outputs, 0)
        XCTAssertTrue(h.key(36))
        XCTAssertEqual(outputs, 1)
        XCTAssertFalse(h.panel.isVisible)
        XCTAssertEqual(h.dismissals, 1)
        animation.progress(0.4); animation.completion()
        XCTAssertFalse(h.panel.isVisible)
        XCTAssertEqual(outputs, 1)
        XCTAssertEqual(h.dismissals, 1)
    }

    func testCompactLiveResizeAndScreenGeometryRetireOldOriginWrites() throws {
        for change in 0...2 {
            let h = EntranceHarness(); defer { h.close() }
            h.panel.show(records: [])
            let window = try XCTUnwrap(h.panel.window), animation = try XCTUnwrap(h.animations.first)
            animation.progress(0.3)
            var preferredHeights: [CGFloat] = []
            h.panel.onPreferredHeightChange = { _, value in preferredHeights.append(value) }
            switch change {
            case 0:
                h.panel.setCompactMode(true)
                XCTAssertEqual(window.frame.height, 376)
            case 1:
                h.panel.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
                var frame = window.frame; frame.size.height = 510
                window.setFrame(frame, display: false)
                h.panel.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
                XCTAssertEqual(preferredHeights.last, 510)
            default:
                h.visibleFrame = NSRect(x: 1800, y: 50, width: 1024, height: 700)
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                XCTAssertTrue(h.visibleFrame.contains(window.frame))
            }
            let final = window.frame
            XCTAssertFalse(h.motion.isAnimating)
            XCTAssertEqual(animation.cancellations, 1)
            XCTAssertEqual(window.alphaValue, 1)
            if change != 1 { XCTAssertTrue(preferredHeights.isEmpty) }
            animation.progress(0.7); animation.completion()
            XCTAssertEqual(window.frame, final)
            XCTAssertEqual(window.alphaValue, 1)
        }
    }

    func testDraftOpeningSettlesEntranceAndHiddenDraftRestoresWithoutNewAnimation() throws {
        let h = EntranceHarness(); defer { h.close() }
        let record = ClipboardRecord(text: "synthetic original draft")
        var detail: NSPanel?
        h.panel.presentDetailPanel = { window, _ in detail = window }
        h.panel.onPrepareEdit = { _, reply in reply(.success(.init(record: record))) }
        h.panel.show(records: [record])
        let animation = try XCTUnwrap(h.animations.first)
        h.panel.edit(record)
        XCTAssertFalse(h.motion.isAnimating)
        XCTAssertEqual(animation.cancellations, 1)
        let editor = try h.find(NSTextView.self, in: detail?.contentView)
        editor.insertText("retained draft", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let undo = try XCTUnwrap(editor.undoManager)
        h.panel.hideForSuspension()
        XCTAssertFalse(h.panel.isVisible)
        XCTAssertTrue(h.panel.hasPreservedDraft)
        animation.progress(0.5); animation.completion()
        XCTAssertFalse(h.panel.isVisible)
        h.visibleFrame = NSRect(x: 1800, y: 50, width: 1280, height: 760)
        h.panel.show(records: [])
        XCTAssertEqual(h.animations.count, 1)
        XCTAssertEqual(h.panel.window?.alphaValue, 1)
        XCTAssertTrue(h.visibleFrame.contains(try XCTUnwrap(h.panel.window?.frame)))
        XCTAssertEqual(editor.string, "retained draft")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertTrue(editor.undoManager === undo)
        XCTAssertTrue(detail?.firstResponder === editor)
    }
}
