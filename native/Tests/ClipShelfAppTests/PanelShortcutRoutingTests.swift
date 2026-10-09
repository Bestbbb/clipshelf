import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class ComposingShortcutEditor: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

@MainActor private final class PanelShortcutHarness {
    let panel = ClipboardPanelController()
    let records: [ClipboardRecord]
    var pastes: [(UUID, Bool)] = []
    var undoCount = 0, pauseCount = 0, newCount = 0, deleteCount = 0
    init(records: [ClipboardRecord]? = nil) {
        self.records = records ?? (0..<3).map { ClipboardRecord(text: "Synthetic shortcut \($0)", copiedAt: Date(timeIntervalSince1970: Double(100 - $0))) }
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView
        window.delegate = panel
        panel.window = window
        panel.onPaste = { [weak self] record, plain in self?.pastes.append((record.id, plain)) }
        panel.onUndo = { [weak self] in self?.undoCount += 1 }
        panel.onPauseToggle = { [weak self] in self?.pauseCount += 1 }
        panel.onNewText = { [weak self] in self?.newCount += 1 }
        panel.onDeleteRecords = { [weak self] _ in self?.deleteCount += 1 }
        panel.show(records: self.records)
    }
    @discardableResult func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                                    windowNumber: panel.window!.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: repeated, keyCode: code)!
        return panel.handleKey(event)
    }
    func view<T: NSView>(_ type: T.Type, label: String? = nil) throws -> T {
        func walk(_ v: NSView) -> T? {
            if let typed = v as? T, label == nil || typed.accessibilityLabel() == label { return typed }
            return v.subviews.lazy.compactMap(walk).first
        }
        return try XCTUnwrap(panel.window?.contentView.flatMap(walk))
    }
    func card(_ index: Int) throws -> ClipboardCardView {
        let collection = try view(NSCollectionView.self)
        let item = panel.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: index, section: 0))
        return try XCTUnwrap(item.view.subviews.first as? ClipboardCardView)
    }
    func close() { panel.dismiss() }
}

final class PanelShortcutRoutingTests: XCTestCase {
    @MainActor private func configured() -> KeyboardShortcutConfiguration {
        var configuration = KeyboardShortcutConfiguration.defaults
        configuration.quickPaste = .option; configuration.plainText = .control
        configuration.previousPinboard = .init(keyCode: 33, modifiers: .control)
        configuration.nextPinboard = .init(keyCode: 30, modifiers: .control)
        return configuration
    }

    @MainActor func testSearchFirstReturnAndConfiguredPlainAndQuickPasteRouteSamePolicy() throws {
        let h = PanelShortcutHarness(); defer { h.close() }
        h.panel.applyShortcuts(configured(), alwaysPlainText: false)
        XCTAssertTrue(h.key(36, "\r"))
        XCTAssertTrue(h.pastes.isEmpty)
        XCTAssertTrue(h.key(36, "\r", flags: .control))
        XCTAssertEqual(h.pastes.last?.0, h.records[0].id); XCTAssertEqual(h.pastes.last?.1, true)
        h.pastes.removeAll()
        XCTAssertFalse(h.key(18, "1", flags: .command))
        XCTAssertTrue(h.pastes.isEmpty)
        XCTAssertTrue(h.key(19, "2", flags: .option))
        XCTAssertEqual(h.pastes.last?.0, h.records[1].id); XCTAssertEqual(h.pastes.last?.1, false)
        XCTAssertTrue(h.key(20, "3", flags: [.option, .control]))
        XCTAssertEqual(h.pastes.last?.0, h.records[2].id); XCTAssertEqual(h.pastes.last?.1, true)
        let count = h.pastes.count
        XCTAssertFalse(h.key(20, "3", flags: [.option, .control, .shift]))
        XCTAssertFalse(h.key(36, "\r", flags: [.control, .shift]))
        XCTAssertEqual(h.pastes.count, count)
    }

    @MainActor func testFixedCommandsFollowLogicalCharactersAndWinOverSavedBoardChord() throws {
        let h = PanelShortcutHarness(); defer { h.close() }
        h.panel.applyShortcuts(.defaults, alwaysPlainText: false)
        h.key(36, "\r")
        XCTAssertTrue(h.key(16, "z", flags: .command))
        XCTAssertEqual(h.undoCount, 1)
        XCTAssertFalse(h.key(16, "Z", flags: [.command, .shift]))
        XCTAssertFalse(h.key(6, "y", flags: .command))
        XCTAssertEqual(h.undoCount, 1)
        // A logical fixed command wins even when its physical code matches the
        // saved board chord; this uses a synthetic collision, independent of the host layout.
        XCTAssertTrue(h.key(123, "z", flags: .command))
        XCTAssertEqual(h.undoCount, 2)
        for (code, character) in [(UInt16(7), "x"), (9, "v"), (12, "q")] {
            XCTAssertFalse(h.key(code, character, flags: .command), "Native app menu keeps cut/paste/quit")
        }
    }

    @MainActor func testSearchEditorKeepsNativeSelectionCopyUndoAndCustomBoardChord() throws {
        let h = PanelShortcutHarness(); defer { h.close() }
        h.panel.applyShortcuts(configured(), alwaysPlainText: false)
        for (code, character) in [(UInt16(0), "a"), (8, "c"), (6, "z"), (18, "1"), (33, "[")] {
            XCTAssertFalse(h.key(code, character, flags: code == 33 ? .control : .command))
        }
        XCTAssertEqual(h.undoCount, 0); XCTAssertTrue(h.pastes.isEmpty)
        XCTAssertTrue(h.key(17, "t", flags: .command)); XCTAssertEqual(h.pauseCount, 1)
    }

    @MainActor func testDiscreteActionsRejectRepeatAndExtraModifiersWhileArrowRepeatsNavigate() {
        let h = PanelShortcutHarness(); defer { h.close() }
        h.key(36, "\r")
        for (code, character, flags) in [(UInt16(6), "z", NSEvent.ModifierFlags.command), (17, "t", .command), (45, "n", .command), (36, "\r", []), (18, "1", .command), (51, "", [])] {
            XCTAssertTrue(h.key(code, character, flags: flags, repeated: true))
        }
        XCTAssertEqual(h.undoCount + h.pauseCount + h.newCount + h.deleteCount, 0)
        XCTAssertTrue(h.pastes.isEmpty)
        XCTAssertFalse(h.key(6, "Z", flags: [.command, .shift]))
        XCTAssertFalse(h.key(51, "", flags: .option))
        XCTAssertFalse(h.key(49, " ", flags: .control))
        XCTAssertFalse(h.key(124, "", flags: .option))
        XCTAssertTrue(h.key(124, "", repeated: true))
        h.key(36, "\r")
        XCTAssertEqual(h.pastes.last?.0, h.records[1].id)
    }

    @MainActor func testMarkedTextAndOtherTextEditorsKeepEveryEditingEvent() throws {
        let h = PanelShortcutHarness(); defer { h.close() }
        let editor = ComposingShortcutEditor(frame: .zero)
        h.panel.window?.contentView?.addSubview(editor)
        XCTAssertTrue(h.panel.window!.makeFirstResponder(editor))
        for (code, char, flags) in [(UInt16(36), "\r", NSEvent.ModifierFlags()), (49, " ", []), (53, "", []), (124, "", []), (6, "z", .command)] {
            XCTAssertFalse(h.key(code, char, flags: flags))
        }
        XCTAssertTrue(h.panel.isVisible); XCTAssertTrue(h.pastes.isEmpty); XCTAssertEqual(h.undoCount, 0)
        let regular = NSTextView(frame: .zero)
        h.panel.window?.contentView?.addSubview(regular)
        XCTAssertTrue(h.panel.window!.makeFirstResponder(regular))
        XCTAssertFalse(h.key(51))
        XCTAssertFalse(h.key(6, "z", flags: .command))
        XCTAssertEqual(h.deleteCount + h.undoCount, 0)
    }

    @MainActor func testDoubleClickUsesConfiguredModifierAndAlwaysPlainKeepsFilesRich() throws {
        let h = PanelShortcutHarness(); defer { h.close() }
        h.panel.applyShortcuts(configured(), alwaysPlainText: false)
        let card = try h.card(0)
        func click(_ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags, timestamp: 1,
                                          windowNumber: h.panel.window!.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 2, pressure: 1)!
            card.mouseDown(with: event)
        }
        click(.shift); XCTAssertEqual(h.pastes.last?.1, false)
        click(.control); XCTAssertEqual(h.pastes.last?.1, true)
        h.panel.applyShortcuts(configured(), alwaysPlainText: true)
        click([]); XCTAssertEqual(h.pastes.last?.1, true)
        let file = ClipboardRecord(text: "Synthetic file", parts: [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data("file:///synthetic/missing.txt".utf8))])])
        h.panel.show(records: [file]); h.key(36, "\r"); h.key(36, "\r")
        XCTAssertEqual(h.pastes.last?.0, file.id); XCTAssertEqual(h.pastes.last?.1, false)
    }

    @MainActor func testQuickBadgesUseConfiguredHeldFlagsAndClearOnReopen() throws {
        let h = PanelShortcutHarness(); defer { h.close() }
        h.panel.applyShortcuts(configured(), alwaysPlainText: false)
        func badge(_ card: ClipboardCardView) -> String? {
            card.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel()?.hasPrefix("Quick Paste ") == true }?.stringValue
        }
        h.panel.handleModifierFlags(.option)
        XCTAssertNil(badge(try h.card(0)), "Search owns keyboard; no Quick badge")
        h.key(36, "\r"); h.panel.handleModifierFlags(.option)
        XCTAssertEqual(badge(try h.card(0)), "⌥1")
        h.panel.handleModifierFlags([.option, .control])
        XCTAssertEqual(badge(try h.card(0)), "⌃⌥1")
        h.panel.handleModifierFlags([])
        XCTAssertNil(badge(try h.card(0)))
        h.panel.handleModifierFlags(.option); h.panel.dismiss(); h.panel.show(records: h.records)
        h.key(36, "\r")
        XCTAssertNil(badge(try h.card(0)))
    }

    @MainActor func testConfiguredBoardNavigationIsLocalAndExact() throws {
        let h = PanelShortcutHarness(); defer { h.close() }
        h.panel.applyShortcuts(configured(), alwaysPlainText: false)
        let boards = [Pinboard(name: "First"), Pinboard(name: "Second")]
        h.panel.setPinboards(boards)
        let popup = try h.view(NSPopUpButton.self, label: "分组")
        XCTAssertEqual(popup.indexOfSelectedItem, 0)
        XCTAssertFalse(h.key(30, "]", flags: .control)) // Search does not change boards.
        h.key(36, "\r")
        XCTAssertTrue(h.key(30, "]", flags: .control))
        XCTAssertEqual(popup.indexOfSelectedItem, 1)
        XCTAssertFalse(h.key(30, "]", flags: [.control, .shift]))
        XCTAssertEqual(popup.indexOfSelectedItem, 1)
        XCTAssertTrue(h.key(30, "]", flags: .control, repeated: true))
        XCTAssertEqual(popup.indexOfSelectedItem, 2)
    }
}
