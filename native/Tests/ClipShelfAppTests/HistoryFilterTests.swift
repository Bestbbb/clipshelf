import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

final class HistoryFilterDraftTests: XCTestCase {
    func testClearKeepsKeywordSortAndNonfilterQueryPolicy() {
        let board = UUID()
        let original = HistoryQuery(text: "关键词", kind: .image, sourceBundleID: "app.synthetic",
                                    copiedAfter: Date(timeIntervalSince1970: 1), copiedBefore: Date(timeIntervalSince1970: 2),
                                    pinboardIDs: [board], includePinned: false, limit: 37,
                                    sortOrder: .pinboard, deviceFilter: .device(UUID()))
        var draft = HistoryFilterDraft(query: original)
        draft.clearFilters()
        XCTAssertEqual(draft.query.text, original.text)
        XCTAssertEqual(draft.query.sortOrder, .pinboard)
        XCTAssertEqual(draft.query.limit, 37); XCTAssertFalse(draft.query.includePinned)
        XCTAssertNil(draft.query.kind); XCTAssertNil(draft.query.sourceBundleID)
        XCTAssertNil(draft.query.copiedAfter); XCTAssertNil(draft.query.copiedBefore)
        XCTAssertEqual(draft.query.deviceFilter, .all); XCTAssertTrue(draft.query.pinboardIDs.isEmpty)
        XCTAssertThrowsError(try draft.validate(availablePinboardIDs: [board])) {
            XCTAssertEqual($0 as? HistoryFilterDraft.ValidationError, .manualOrderRequiresOneBoard)
        }
        XCTAssertEqual(original.kind, .image, "Draft changes cannot change the original value query")
    }

    func testDatesAreInclusiveMayBeOneSidedAndCannotReverseOrBeNonfinite() throws {
        let date = Date(timeIntervalSince1970: 100)
        for (start, end): (Date?, Date?) in [(nil, nil), (date, nil), (nil, date), (date, date)] {
            let draft = HistoryFilterDraft(query: HistoryQuery(copiedAfter: start, copiedBefore: end))
            XCTAssertNoThrow(try draft.validate(availablePinboardIDs: []))
        }
        XCTAssertThrowsError(try HistoryFilterDraft(query: HistoryQuery(copiedAfter: date, copiedBefore: date.addingTimeInterval(-1))).validate(availablePinboardIDs: [])) {
            XCTAssertEqual($0 as? HistoryFilterDraft.ValidationError, .reversedDates)
        }
        XCTAssertThrowsError(try HistoryFilterDraft(query: HistoryQuery(copiedAfter: Date(timeIntervalSinceReferenceDate: .infinity))).validate(availablePinboardIDs: [])) {
            XCTAssertEqual($0 as? HistoryFilterDraft.ValidationError, .invalidDate)
        }
    }

    func testMissingBoardsMustBeExplicitlyRemovedRatherThanBroadeningQuery() {
        let a = UUID(), b = UUID()
        let draft = HistoryFilterDraft(query: HistoryQuery(pinboardIDs: [a, b]))
        XCTAssertThrowsError(try draft.validate(availablePinboardIDs: [a])) {
            XCTAssertEqual($0 as? HistoryFilterDraft.ValidationError, .unavailablePinboards(1))
        }
        XCTAssertEqual(draft.query.pinboardIDs, [a, b])
    }

    func testMissingSourceAndDeviceRemainValidExplicitEmptyResultConditions() throws {
        let device = UUID()
        let options = HistoryFilterOptions(pinboards: [], sources: [:], devices: [:], localDeviceID: nil)
        let draft = HistoryFilterDraft(query: HistoryQuery(sourceBundleID: "app.vanished", deviceFilter: .device(device)))
        XCTAssertNoThrow(try draft.validate(availablePinboardIDs: []))
        let notice = try XCTUnwrap(draft.availabilityNotice(options: options))
        XCTAssertTrue(notice.contains("App")); XCTAssertTrue(notice.contains("设备"))
        XCTAssertEqual(draft.query.sourceBundleID, "app.vanished")
        XCTAssertEqual(draft.query.deviceFilter, .device(device))
    }

    func testManualOrderOnlyPermittedForExactlyOneExistingBoard() {
        let a = UUID(), b = UUID()
        for ids: Set<UUID> in [[], [a, b]] {
            XCTAssertThrowsError(try HistoryFilterDraft(query: HistoryQuery(pinboardIDs: ids, sortOrder: .pinboard)).validate(availablePinboardIDs: [a, b]))
        }
        XCTAssertNoThrow(try HistoryFilterDraft(query: HistoryQuery(pinboardIDs: [a], sortOrder: .pinboard)).validate(availablePinboardIDs: [a, b]))
    }
}

@MainActor private final class FilterTestWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) {}
}
@MainActor private final class FilterComposingEditor: NSTextView { override func hasMarkedText() -> Bool { true } }

@MainActor private final class FilterHarness {
    let controller: HistoryFilterController
    let window: FilterTestWindow
    var applied: [HistoryQuery] = []
    var cancellations = 0
    init(query: HistoryQuery = HistoryQuery(), options: HistoryFilterOptions = HistoryFilterOptions(pinboards: [], sources: [:], devices: [:], localDeviceID: nil)) {
        controller = HistoryFilterController(query: query, options: options)
        window = FilterTestWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.onApply = { [weak self] in self?.applied.append($0) }
        controller.onCancel = { [weak self] in self?.cancellations += 1 }
    }
    func all<T: NSView>(_ type: T.Type) -> [T] {
        func walk(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(walk) }
        return walk(controller.view)
    }
    func view<T: NSView>(_ type: T.Type, label: String) throws -> T { try XCTUnwrap(all(type).first { $0.accessibilityLabel() == label }) }
    func button(_ title: String) throws -> NSButton { try XCTUnwrap(all(NSButton.self).first { $0.title == title }) }
    func choose(label: String, key: String) throws {
        let popup = try view(NSPopUpButton.self, label: label)
        popup.select(try XCTUnwrap(popup.itemArray.first { $0.representedObject as? String == key }))
        popup.sendAction(popup.action, to: popup.target)
    }
    func press(_ title: String) throws { try button(title).performClick(nil) }
    func event(_ code: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}

final class HistoryFilterControllerTests: XCTestCase {
    @MainActor func testAllDimensionsLoadIntoDraftAndApplyExactlyOnce() throws {
        let board = Pinboard(name: "中文分组"), device = UUID()
        let query = HistoryQuery(text: "中文搜索", kind: .link, sourceBundleID: "app.browser",
                                 copiedAfter: Date(timeIntervalSince1970: 10), copiedBefore: Date(timeIntervalSince1970: 20),
                                 pinboardIDs: [board.id], includePinned: false, limit: 300,
                                 sortOrder: .pinboard, deviceFilter: .device(device))
        let h = FilterHarness(query: query, options: .init(pinboards: [board], sources: ["app.browser": "浏览器"], devices: [device: "测试 Mac"], localDeviceID: device))
        XCTAssertTrue(h.applied.isEmpty)
        XCTAssertEqual(try h.view(NSPopUpButton.self, label: "全部筛选：内容类型").selectedItem?.representedObject as? String, "link")
        XCTAssertEqual(try h.view(NSPopUpButton.self, label: "全部筛选：来源 App").selectedItem?.representedObject as? String, "source:app.browser")
        XCTAssertEqual(try h.view(NSPopUpButton.self, label: "全部筛选：来源设备").selectedItem?.representedObject as? String, device.uuidString)
        XCTAssertEqual(try h.button("中文分组").state, .on)
        XCTAssertEqual(try h.view(NSPopUpButton.self, label: "全部筛选：排列顺序").indexOfSelectedItem, 1)
        try h.press("应用筛选"); h.controller.perform(NSSelectorFromString("applyDraft"))
        XCTAssertEqual(h.applied.count, 1)
        let value = try XCTUnwrap(h.applied.first)
        XCTAssertEqual(value.text, query.text); XCTAssertEqual(value.kind, query.kind)
        XCTAssertEqual(value.sourceBundleID, query.sourceBundleID); XCTAssertEqual(value.deviceFilter, query.deviceFilter)
        XCTAssertEqual(value.copiedAfter, query.copiedAfter); XCTAssertEqual(value.copiedBefore, query.copiedBefore)
        XCTAssertEqual(value.pinboardIDs, query.pinboardIDs); XCTAssertEqual(value.sortOrder, .pinboard)
        XCTAssertFalse(value.includePinned); XCTAssertEqual(value.limit, 300)
    }

    @MainActor func testDraftChangesThenCancelOrExternalCloseNeverApply() throws {
        for external in [false, true] {
            let h = FilterHarness(query: HistoryQuery(text: "保留关键词"))
            try h.choose(label: "全部筛选：内容类型", key: "image")
            XCTAssertEqual(h.controller.draft.query.kind, .image)
            XCTAssertTrue(h.applied.isEmpty)
            if external { h.window.contentView = nil; h.window.orderOut(nil) }
            else { try h.press("取消") }
            XCTAssertTrue(h.applied.isEmpty)
            XCTAssertEqual(h.cancellations, external ? 0 : 1)
        }
    }

    @MainActor func testClearOnlyChangesDraftAndKeepsKeywordAndManualOrderUntilCorrected() throws {
        let board = Pinboard(name: "保留排序")
        let h = FilterHarness(query: HistoryQuery(text: "关键词", kind: .color, pinboardIDs: [board.id], sortOrder: .pinboard),
                              options: .init(pinboards: [board], sources: [:], devices: [:], localDeviceID: nil))
        try h.press("清除筛选")
        XCTAssertTrue(h.applied.isEmpty)
        XCTAssertEqual(h.controller.draft.query.text, "关键词")
        XCTAssertEqual(h.controller.draft.query.sortOrder, .pinboard)
        XCTAssertTrue(h.controller.draft.query.pinboardIDs.isEmpty)
        XCTAssertFalse(try h.button("应用筛选").isEnabled)
        let order = try h.view(NSPopUpButton.self, label: "全部筛选：排列顺序")
        order.selectItem(at: 0); order.sendAction(order.action, to: order.target)
        try h.press("应用筛选")
        XCTAssertEqual(h.applied.count, 1); XCTAssertEqual(h.applied.first?.text, "关键词")
    }

    @MainActor func testOptionRefreshPreservesMissingDraftValuesAndRejectsMissingBoard() throws {
        let board = Pinboard(name: "稍后消失"), device = UUID()
        let h = FilterHarness(query: HistoryQuery(sourceBundleID: "all", pinboardIDs: [board.id], deviceFilter: .device(device)),
                              options: .init(pinboards: [board], sources: ["all": "合法来源标识 all"], devices: [device: "Mac"], localDeviceID: nil))
        h.controller.updateOptions(.init(pinboards: [], sources: [:], devices: [:], localDeviceID: nil))
        XCTAssertEqual(h.controller.draft.query.pinboardIDs, [board.id])
        XCTAssertEqual(h.controller.draft.query.sourceBundleID, "all")
        XCTAssertEqual(h.controller.draft.query.deviceFilter, .device(device))
        XCTAssertFalse(try h.button("应用筛选").isEnabled)
        let missing = try XCTUnwrap(h.all(NSButton.self).first { $0.title.hasPrefix("已不可用分组") })
        missing.performClick(nil)
        XCTAssertTrue(try h.button("应用筛选").isEnabled)
        try h.press("应用筛选")
        XCTAssertEqual(h.applied.first?.sourceBundleID, "all")
        XCTAssertEqual(h.applied.first?.deviceFilter, .device(device))
    }

    @MainActor func testDateBoundsAndPresetsRemainDraftUntilApply() throws {
        let h = FilterHarness()
        let date = try h.view(NSPopUpButton.self, label: "全部筛选：复制时间")
        date.selectItem(at: 2); date.sendAction(date.action, to: date.target)
        XCTAssertNotNil(h.controller.draft.query.copiedAfter); XCTAssertNil(h.controller.draft.query.copiedBefore)
        date.selectItem(at: 4); date.sendAction(date.action, to: date.target)
        let start = try h.view(NSDatePicker.self, label: "复制时间开始（含）")
        let end = try h.view(NSDatePicker.self, label: "复制时间结束（含）")
        start.dateValue = Date(timeIntervalSince1970: 200); end.dateValue = Date(timeIntervalSince1970: 100)
        start.sendAction(start.action, to: start.target)
        XCTAssertFalse(try h.button("应用筛选").isEnabled)
        end.dateValue = start.dateValue; end.sendAction(end.action, to: end.target)
        XCTAssertTrue(try h.button("应用筛选").isEnabled)
        XCTAssertTrue(h.applied.isEmpty)
        try h.press("应用筛选")
        XCTAssertEqual(h.applied.first?.copiedAfter, h.applied.first?.copiedBefore)
    }

    @MainActor func testReturnAppliesAndEscapeCancelsThroughRealUnshownWindow() throws {
        let h = FilterHarness()
        h.controller.focusInitialControl()
        XCTAssertNotNil(h.window.firstResponder)
        XCTAssertTrue(h.window.performKeyEquivalent(with: h.event(36, characters: "\r")))
        XCTAssertEqual(h.applied.count, 1)
        let other = FilterHarness()
        other.controller.focusInitialControl()
        XCTAssertTrue(other.window.performKeyEquivalent(with: other.event(53, characters: "\u{1b}")))
        XCTAssertEqual(other.cancellations, 1); XCTAssertTrue(other.applied.isEmpty)
    }

    @MainActor func testMarkedTextKeepsReturnAndEscapeAwayFromApplyAndCancel() {
        let h = FilterHarness()
        let editor = FilterComposingEditor(frame: .zero)
        h.controller.view.addSubview(editor)
        XCTAssertTrue(h.window.makeFirstResponder(editor))
        XCTAssertFalse(h.window.performKeyEquivalent(with: h.event(36, characters: "\r")))
        XCTAssertFalse(h.window.performKeyEquivalent(with: h.event(53, characters: "\u{1b}")))
        XCTAssertTrue(h.applied.isEmpty); XCTAssertEqual(h.cancellations, 0)
    }

    @MainActor func testSmallHeightKeepsErrorsAndActionsVisibleAndAllConditionsReachable() throws {
        let boards = (0..<100).map { Pinboard(name: "中文合成分组 \($0)") }
        let h = FilterHarness(options: .init(pinboards: boards, sources: [:], devices: [:], localDeviceID: nil))
        h.window.setContentSize(NSSize(width: 420, height: 360))
        h.controller.view.layoutSubtreeIfNeeded()
        let root = h.controller.view
        for title in ["清除筛选", "取消", "应用筛选"] {
            let button = try h.button(title)
            XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)), title)
        }
        let status = try h.view(NSTextField.self, label: "筛选状态")
        XCTAssertTrue(root.bounds.contains(status.convert(status.bounds, to: root)))
        for label in ["全部筛选条件", "全部筛选：分组列表"] {
            let scroll = try h.view(NSScrollView.self, label: label)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        }
    }
    @MainActor func testIdenticalOptionRefreshKeepsSameFocusedBoardControl() throws {
        let a = Pinboard(name: "A"), b = Pinboard(name: "B")
        let options = HistoryFilterOptions(pinboards: [a, b], sources: [:], devices: [:], localDeviceID: nil)
        let h = FilterHarness(options: options)
        let focused = try h.button("B")
        XCTAssertTrue(h.window.makeFirstResponder(focused))
        // Mirrors the three independent option setters in a page-load receipt.
        for _ in 0..<3 { h.controller.updateOptions(options) }
        XCTAssertTrue(h.window.firstResponder === focused)
        XCTAssertTrue(try h.button("B") === focused)
        (h.window.firstResponder as? NSButton)?.performClick(nil)
        XCTAssertEqual(h.controller.draft.query.pinboardIDs, [b.id])
        XCTAssertTrue(h.applied.isEmpty)
    }

    @MainActor func testChangedOptionsRestoreBoardFocusByIDAfterRenameAndReorder() throws {
        let a = Pinboard(name: "A"), b = Pinboard(name: "B"), c = Pinboard(name: "C")
        let h = FilterHarness(options: .init(pinboards: [a, b], sources: [:], devices: [:], localDeviceID: nil))
        XCTAssertTrue(h.window.makeFirstResponder(try h.button("B")))
        var renamed = b; renamed.name = "B 新名称"
        h.controller.updateOptions(.init(pinboards: [renamed, c, a], sources: ["new.app": "New"], devices: [:], localDeviceID: nil))
        let replacement = try h.button("B 新名称")
        XCTAssertTrue(h.window.firstResponder === replacement)
        (h.window.firstResponder as? NSButton)?.performClick(nil)
        XCTAssertEqual(h.controller.draft.query.pinboardIDs, [b.id])
        XCTAssertTrue(h.applied.isEmpty)
    }

    @MainActor func testRemovedSelectedBoardRetainsFocusedPlaceholderAndCanBeUnchecked() throws {
        let a = Pinboard(name: "A"), b = Pinboard(name: "B")
        let h = FilterHarness(query: HistoryQuery(pinboardIDs: [b.id]), options: .init(pinboards: [a, b], sources: [:], devices: [:], localDeviceID: nil))
        XCTAssertTrue(h.window.makeFirstResponder(try h.button("B")))
        h.controller.updateOptions(.init(pinboards: [a], sources: [:], devices: [:], localDeviceID: nil))
        let replacement = try XCTUnwrap(h.window.firstResponder as? NSButton)
        XCTAssertTrue(replacement.title.hasPrefix("已不可用分组"))
        XCTAssertFalse(try h.button("应用筛选").isEnabled)
        replacement.performClick(nil)
        XCTAssertTrue(h.controller.draft.query.pinboardIDs.isEmpty)
        XCTAssertTrue(try h.button("应用筛选").isEnabled)
        XCTAssertTrue(h.applied.isEmpty)
    }

    @MainActor func testRemovedUnselectedFocusedBoardMovesToAvailableBoardThenFirstControl() throws {
        let a = Pinboard(name: "A"), b = Pinboard(name: "B"), c = Pinboard(name: "C")
        let h = FilterHarness(options: .init(pinboards: [a, b, c], sources: [:], devices: [:], localDeviceID: nil))
        XCTAssertTrue(h.window.makeFirstResponder(try h.button("B")))
        h.controller.updateOptions(.init(pinboards: [a, c], sources: [:], devices: [:], localDeviceID: nil))
        XCTAssertTrue(h.window.firstResponder === (try h.button("C")))
        (h.window.firstResponder as? NSButton)?.performClick(nil)
        XCTAssertEqual(h.controller.draft.query.pinboardIDs, [c.id])
        (h.window.firstResponder as? NSButton)?.performClick(nil)
        h.controller.updateOptions(.init(pinboards: [], sources: [:], devices: [:], localDeviceID: nil))
        XCTAssertTrue(h.window.firstResponder === (try h.view(NSPopUpButton.self, label: "全部筛选：内容类型")))
        XCTAssertTrue(h.controller.draft.query.pinboardIDs.isEmpty)
        XCTAssertTrue(h.applied.isEmpty)
    }

}
