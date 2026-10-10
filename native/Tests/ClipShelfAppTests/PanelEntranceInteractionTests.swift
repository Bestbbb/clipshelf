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
    func testDestinationPickerSelectsAnExplicitApplicationAndOwnsItsReturnKey() throws {
        let h = EntranceHarness(); defer { h.close() }
        h.panel.show(records: [ClipboardRecord(text: "synthetic picker")])
        h.panel.setPasteDestinations([(200, "TextEdit"), (201, "Chrome")], selectedPID: nil)
        h.panel.setPasteDestination(name: nil, available: false, requiresChoice: true)
        func picker(_ view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton, popup.accessibilityIdentifier() == "shelf.destination" { return popup }
            return view.subviews.lazy.compactMap(picker).first
        }
        let popup = try XCTUnwrap(picker(h.panel.window!.contentView!))
        var selected: Int32?
        h.panel.onSelectPasteDestination = { selected = $0 }
        XCTAssertFalse(popup.isHidden)
        XCTAssertEqual(popup.selectedItem?.tag, -1)
        popup.selectItem(withTag: 201)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(selected, 201)
        let menu = try XCTUnwrap(popup.menu)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertFalse(h.key(36)); XCTAssertFalse(h.key(53))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertTrue(h.panel.isVisible)
    }

    func testNativeMenuOwnsReturnAndEscapeUntilTrackingEnds() throws {
        let h = EntranceHarness(); defer { h.close() }
        let record = ClipboardRecord(text: "menu must not paste")
        var pastes = 0
        h.panel.resolveOutputSelection = { _, reply in reply(.success([record])) }
        h.panel.onPaste = { _, _ in pastes += 1 }
        h.panel.show(records: [record])
        let collection = try h.find(NSCollectionView.self)
        let item = h.panel.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        let card = try XCTUnwrap(item.view.subviews.compactMap { $0 as? ClipboardCardView }.first)
        let menuItems = try XCTUnwrap(card.menu?.items)
        XCTAssertFalse(menuItems.contains { $0.keyEquivalent == "\r" }, "Return must confirm the highlighted submenu item, not an unrelated Paste equivalent")
        XCTAssertTrue(h.key(36)) // enter results
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertFalse(h.key(36)); XCTAssertFalse(h.key(53))
        XCTAssertEqual(pastes, 0); XCTAssertTrue(h.panel.isVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertTrue(h.key(36)); XCTAssertEqual(pastes, 1)
    }

    func testVisiblePrimaryActionPastesOnceAndCopyOnlyRemainsVisible() throws {
        let h = EntranceHarness(); defer { h.close() }
        let record = ClipboardRecord(text: "visible primary action")
        h.panel.resolveOutputSelection = { _, reply in reply(.success([record])) }
        h.panel.show(records: [record])
        func button(_ id: String) throws -> NSButton {
            func walk(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.accessibilityIdentifier() == id { return b }
                return v.subviews.lazy.compactMap(walk).first
            }
            return try XCTUnwrap(walk(h.panel.window!.contentView!))
        }
        let primary = try button("shelf.paste")
        var pastes = 0, copies = 0
        h.panel.onPaste = { value, _ in XCTAssertEqual(value.id, record.id); pastes += 1 }
        h.panel.onCopy = { value in XCTAssertEqual(value.id, record.id); copies += 1 }
        h.panel.setPasteDestination(name: "TextEdit", available: true)
        XCTAssertTrue(primary.title.contains("TextEdit"))
        XCTAssertTrue(primary.isEnabled)
        primary.performClick(nil)
        XCTAssertEqual(pastes, 1); XCTAssertEqual(copies, 0)
        h.panel.setPasteDestination(name: nil, available: false)
        primary.performClick(nil)
        XCTAssertEqual(pastes, 1); XCTAssertEqual(copies, 1)
        XCTAssertTrue(h.panel.isVisible)

        let history = try button("pinboard.all"), create = try button("pinboard.create")
        let width: CGFloat = 720
        h.panel.window?.setContentSize(NSSize(width: width, height: 330))
        h.panel.window?.contentView?.layoutSubtreeIfNeeded()
        let historyRect = history.convert(history.bounds, to: h.panel.window?.contentView)
        let createRect = create.convert(create.bounds, to: h.panel.window?.contentView)
        XCTAssertGreaterThanOrEqual(historyRect.width, 104)
        XCTAssertLessThanOrEqual(historyRect.maxX, createRect.minX)
        XCTAssertLessThan(createRect.maxX, width)
        XCTAssertFalse(history.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(create.isHiddenOrHasHiddenAncestor)
    }

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
        XCTAssertFalse(h.panel.isVisible, "One Escape must end the invocation even with a search query")
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
                XCTAssertEqual(window.frame.height, 240, "Compact mode uses the current 240-point shelf")
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
