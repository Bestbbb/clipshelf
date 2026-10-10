import AppKit
import ClipShelfLocalization
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

/// Tests the panel/strip adapter and deferred persistence without displaying a window.
@MainActor private final class PinboardPanelHarness {
    struct Save {
        let ids: [UUID]
        let expected: [UUID]
        let complete: (Result<[Pinboard], Error>) -> Void
    }

    let panel = ClipboardPanelController()
    let boards = [Pinboard(name: "Alpha"), Pinboard(name: "Beta"), Pinboard(name: "Gamma")]
    var saves: [Save] = []
    var requests: [PanelPageRequest] = []
    var visibleFrame = NSRect(x: 0, y: 0, width: 1160, height: 900)

    init() {
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                     styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView
        window.delegate = panel; panel.window = window
        panel.resolveVisibleScreenFrame = { [weak self] _ in self?.visibleFrame ?? .zero }
        panel.onReorderPinboards = { [weak self] ids, expected, complete in
            self?.saves.append(Save(ids: ids, expected: expected, complete: complete))
        }
        panel.onPageRequest = { [weak self] request, complete in
            guard let self else { return }
            self.requests.append(request)
            let records = self.boards.filter {
                request.query.pinboardIDs.isEmpty || request.query.pinboardIDs.contains($0.id)
            }.map { board in
                ClipboardRecordMetadata(id: board.id, text: "Synthetic \(board.name)", sourceApp: nil,
                    sourceBundleID: nil, copiedAt: Date(timeIntervalSince1970: 1), renamedTitle: nil,
                    ocrText: nil, pinboardID: board.id, pinboardOrder: 0, isInHistory: true,
                    revision: 1, kind: .text, representationTypes: [], originDeviceID: nil,
                    originDeviceName: nil, originDeviceConflict: false)
            }
            complete(.success(.init(records: records, offset: 0, hasMore: false, focusID: nil)))
        }
        panel.setPinboards(boards)
        panel.show(metadata: [], status: "Fixture status")
    }

    var ids: [UUID] { boards.map(\.id) }
    var descendants: [NSView] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return panel.window?.contentView.map(all) ?? []
    }
    var texts: [String] { descendants.compactMap { ($0 as? NSTextField)?.stringValue } }

    func view<T: NSView>(_ type: T.Type, label: String? = nil) throws -> T {
        try XCTUnwrap(descendants.compactMap { $0 as? T }.first { label == nil || $0.accessibilityLabel() == L10n.text(LocalizedMessage(stringLiteral: label!)) })
    }
    func strip() throws -> PinboardTabStrip { try view(PinboardTabStrip.self) }
    func popup() throws -> NSPopUpButton { try view(NSPopUpButton.self, label: "分组") }
    func order() throws -> [UUID] { try popup().itemArray.compactMap { $0.representedObject as? UUID } }
    func selected() throws -> UUID? { try popup().selectedItem?.representedObject as? UUID }
    func tabOrder() throws -> [String?] { try strip().tabButtons.map { $0.accessibilityIdentifier() } }
    func tabIDs(_ boards: [Pinboard]) -> [String?] { boards.map { "pinboard." + $0.id.uuidString } }

    func reordered(_ ids: [UUID]) -> [Pinboard] { ids.compactMap { id in boards.first { $0.id == id } } }
    func drag(_ ids: [UUID], expected: [UUID]? = nil) throws { try strip().onReorder?(ids, expected ?? self.ids) }
    func select(_ id: UUID?) throws { try strip().onSelect?(id) }
    func menu(_ action: String) { panel.perform(NSSelectorFromString(action)) }
    func menuItem(_ action: String) throws -> NSMenuItem {
        try XCTUnwrap(descendants.compactMap { $0 as? NSPopUpButton }.flatMap(\.itemArray)
            .first { $0.action == NSSelectorFromString(action) })
    }

    @discardableResult func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> Bool {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: try XCTUnwrap(panel.window).windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        return panel.handleKey(event)
    }

    func focusResults() throws { panel.window?.makeFirstResponder(try view(NSCollectionView.self, label: "剪贴板搜索结果")) }
    func search(_ text: String) throws {
        let field = try view(NSSearchField.self)
        panel.window?.makeFirstResponder(field)
        field.stringValue = text
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    func close() { panel.dismiss() }
}

@MainActor final class PinboardPanelIntegrationTests: XCTestCase {
    func testTabsPopupAndKeyboardNavigateTheSameBoardAndManualOrder() throws {
        let h = PinboardPanelHarness(); defer { h.close() }
        let tabs = try h.strip(), popup = try h.popup()
        XCTAssertEqual(try h.tabOrder(), h.tabIDs(h.boards))
        XCTAssertEqual(tabs.allButton.state, .on)
        try h.select(h.ids[1])
        XCTAssertEqual(try h.selected(), h.ids[1])
        XCTAssertEqual(h.requests.last?.query.pinboardIDs, [h.ids[1]])
        XCTAssertEqual(h.requests.last?.query.sortOrder, .pinboard)
        XCTAssertEqual(tabs.tabButtons.map(\.state), [.off, .on, .off])

        popup.selectItem(at: 1); h.menu("boardChanged")
        XCTAssertEqual(h.requests.last?.query.pinboardIDs, [h.ids[0]])
        XCTAssertEqual(tabs.tabButtons.map(\.state), [.on, .off, .off])
        try h.focusResults()
        XCTAssertTrue(try h.key(124, flags: .command))
        XCTAssertEqual(try h.selected(), h.ids[1])
        XCTAssertEqual(tabs.tabButtons.map(\.state), [.off, .on, .off])
        XCTAssertTrue(try h.key(123, flags: .command))
        XCTAssertEqual(try h.selected(), h.ids[0])

        try h.select(nil)
        XCTAssertNil(try h.selected())
        XCTAssertTrue(try XCTUnwrap(h.requests.last).query.pinboardIDs.isEmpty)
        XCTAssertEqual(h.requests.last?.query.sortOrder, .recent)
        XCTAssertEqual(tabs.allButton.state, .on)
        XCTAssertTrue(tabs.tabButtons.allSatisfy { $0.state == .off })
    }

    func testDragAndMenuSubmitTheExactStartingOrderWithoutOptimisticChanges() throws {
        for drag in [true, false] {
            let h = PinboardPanelHarness(); defer { h.close() }
            try h.select(h.ids[1])
            let target = [h.ids[1], h.ids[0], h.ids[2]]
            if drag { try h.drag(target) } else { h.menu("moveBoardEarlier") }
            let save = try XCTUnwrap(h.saves.first)
            XCTAssertEqual(save.ids, target)
            XCTAssertEqual(save.expected, h.ids)
            XCTAssertEqual(try h.order(), h.ids)
            XCTAssertEqual(try h.tabOrder(), h.tabIDs(h.boards))
            XCTAssertTrue(try h.strip().isSaving)
            save.complete(.success(h.reordered(target)))
            XCTAssertFalse(try h.strip().isSaving)
            XCTAssertEqual(try h.order(), target)
            XCTAssertEqual(try h.tabOrder(), h.tabIDs(h.reordered(target)))
            XCTAssertEqual(try h.selected(), h.ids[1])
        }
    }

    func testOnlyOneSaveCanBeInFlightAndFailureRetainsOrderForRetry() throws {
        let h = PinboardPanelHarness(); defer { h.close() }
        try h.select(h.ids[1])
        let target = [h.ids[1], h.ids[0], h.ids[2]]
        try h.drag(target)
        try h.drag(Array(h.ids.reversed()))
        h.menu("moveBoardEarlier"); h.menu("moveBoardLater")
        XCTAssertEqual(h.saves.count, 1)
        XCTAssertFalse(h.panel.validateMenuItem(try h.menuItem("moveBoardEarlier")))
        XCTAssertFalse(h.panel.validateMenuItem(try h.menuItem("moveBoardLater")))
        h.saves[0].complete(.failure(HistoryStoreError.invalidPinboardOrder))
        XCTAssertFalse(try h.strip().isSaving)
        XCTAssertEqual(try h.order(), h.ids)
        XCTAssertTrue(h.texts.contains(L10n.text("分组列表已改变，顺序未保存；请刷新后重试。")))
        XCTAssertTrue(h.panel.validateMenuItem(try h.menuItem("moveBoardEarlier")))
        try h.drag(target)
        XCTAssertEqual(h.saves.count, 2)
        XCTAssertEqual(h.saves[1].expected, h.ids)
    }

    func testDuplicateOldReceiptCannotChangeNewOrderOrReleaseAnotherPendingSave() throws {
        let h = PinboardPanelHarness(); defer { h.close() }
        let firstOrder = Array(h.ids.reversed())
        try h.drag(firstOrder)
        let first = try XCTUnwrap(h.saves.first)
        first.complete(.success(h.reordered(firstOrder)))
        try h.drag(h.ids, expected: firstOrder)
        XCTAssertEqual(h.saves.count, 2)
        first.complete(.success(h.boards))
        first.complete(.failure(HistoryStoreError.invalidPinboardOrder))
        XCTAssertTrue(try h.strip().isSaving)
        XCTAssertEqual(try h.order(), firstOrder)
        XCTAssertFalse(h.texts.contains(L10n.text("分组列表已改变，顺序未保存；请刷新后重试。")))
        h.saves[1].complete(.success(h.boards))
        XCTAssertFalse(try h.strip().isSaving)
        XCTAssertEqual(try h.order(), h.ids)
    }

    func testBackgroundRenameOrReorderRejectsOldSuccessAndFailureReceipts() throws {
        for rename in [true, false] {
            for succeeds in [true, false] {
                let h = PinboardPanelHarness(); defer { h.close() }
                try h.drag(Array(h.ids.reversed()))
                var updated = h.boards
                if rename { updated[1].name = "Renamed elsewhere" }
                else { updated.swapAt(0, 1) }
                h.panel.setPinboards(updated)
                let currentTexts = h.texts
                h.saves[0].complete(succeeds ? .success(h.reordered(Array(h.ids.reversed())))
                                           : .failure(HistoryStoreError.invalidPinboardOrder))
                XCTAssertEqual(try h.order(), updated.map(\.id))
                XCTAssertEqual(try h.popup().itemTitles, [L10n.text("全部内容")] + updated.map(\.name))
                XCTAssertEqual(try h.tabOrder(), h.tabIDs(updated))
                XCTAssertEqual(h.texts, currentTexts)
                XCTAssertFalse(try h.strip().isSaving)
            }
        }
    }

    func testUnchangedBackgroundListDoesNotInvalidateValidReceipt() throws {
        let h = PinboardPanelHarness(); defer { h.close() }
        let target = Array(h.ids.reversed())
        try h.drag(target)
        h.panel.setPinboards(h.boards)
        h.saves[0].complete(.success(h.reordered(target)))
        XCTAssertEqual(try h.order(), target)
        XCTAssertEqual(try h.tabOrder(), h.tabIDs(h.reordered(target)))
    }

    func testHiddenAndReopenedSessionRejectsOldReceiptWithoutOverwritingNewStatusOrFocus() throws {
        for reopenBeforeCompletion in [false, true] {
            let h = PinboardPanelHarness(); defer { h.close() }
            try h.drag(Array(h.ids.reversed()))
            h.panel.hideForSuspension()
            if reopenBeforeCompletion { h.panel.show(metadata: [], status: "New session status") }
            let responder = h.panel.window?.firstResponder
            h.saves[0].complete(.success(h.reordered(Array(h.ids.reversed()))))
            XCTAssertEqual(try h.order(), h.ids)
            XCTAssertFalse(try h.strip().isSaving)
            XCTAssertTrue(h.panel.window?.firstResponder === responder)
            if reopenBeforeCompletion {
                XCTAssertTrue(h.texts.contains("New session status"))
                try h.drag(Array(h.ids.reversed()))
                XCTAssertEqual(h.saves.count, 2)
            } else {
                XCTAssertFalse(h.panel.isVisible)
                try h.drag(Array(h.ids.reversed()))
                XCTAssertEqual(h.saves.count, 1)
                h.panel.show(metadata: [])
                XCTAssertEqual(try h.order(), h.ids)
            }
        }
    }

    func testSuccessDuringSearchPreservesSearchScopeQueryAndFirstResponder() throws {
        let h = PinboardPanelHarness(); defer { h.close() }
        try h.select(h.ids[0])
        try h.drag(Array(h.ids.reversed()))
        try h.search("Synthetic Beta")
        let responder = h.panel.window?.firstResponder, requestCount = h.requests.count
        h.saves[0].complete(.success(h.reordered(Array(h.ids.reversed()))))
        XCTAssertEqual(try h.view(NSSearchField.self).stringValue, "Synthetic Beta")
        XCTAssertNil(try h.selected())
        XCTAssertEqual(try h.strip().allButton.state, .on)
        XCTAssertTrue(try XCTUnwrap(h.requests.last).query.pinboardIDs.isEmpty)
        XCTAssertEqual(h.requests.last?.query.text, "Synthetic Beta")
        XCTAssertEqual(h.requests.count, requestCount, "A saved list must not start a query for its former board")
        XCTAssertTrue(h.panel.window?.firstResponder === responder)
    }

    func testReceiptDuringNewBoardNavigationKeepsNewBoardAndDoesNotReplaceItsStatus() throws {
        for succeeds in [true, false] {
            let h = PinboardPanelHarness(); defer { h.close() }
            try h.select(h.ids[0])
            try h.drag(Array(h.ids.reversed()))
            try h.select(h.ids[2]); try h.focusResults()
            let responder = h.panel.window?.firstResponder, requests = h.requests.count, texts = h.texts
            h.saves[0].complete(succeeds ? .success(h.reordered(Array(h.ids.reversed())))
                                       : .failure(HistoryStoreError.invalidPinboardOrder))
            XCTAssertEqual(try h.selected(), h.ids[2])
            XCTAssertEqual(h.requests.last?.query.pinboardIDs, [h.ids[2]])
            XCTAssertEqual(h.requests.count, requests)
            XCTAssertTrue(h.panel.window?.firstResponder === responder)
            if !succeeds { XCTAssertEqual(h.texts, texts) }
        }
    }

    func testMalformedStaleAndNoopReorderIntentsNeverReachPersistence() throws {
        let h = PinboardPanelHarness(); defer { h.close() }
        try h.drag(h.ids)
        try h.drag(Array(h.ids.reversed()), expected: [h.ids[1], h.ids[0], h.ids[2]])
        try h.drag([h.ids[0], h.ids[0], h.ids[2]])
        try h.drag(Array(h.ids.dropLast()))
        try h.drag([h.ids[0], h.ids[1], UUID()])
        XCTAssertTrue(h.saves.isEmpty)
        XCTAssertEqual(try h.order(), h.ids)
        let requests = h.requests.count
        try h.select(UUID())
        XCTAssertEqual(h.requests.count, requests)
        XCTAssertNil(try h.selected())
    }

    func testCompactHeightPreservesUsableLegacySizeAndClampsTooSmallSize() throws {
        for (requested, expected): (CGFloat, CGFloat) in [(338, 338), (1, 240)] {
            let h = PinboardPanelHarness(); defer { h.close() }
            h.panel.setPreferredHeights(normal: 430, compact: requested)
            h.panel.setCompactMode(true)
            try assertLayout(h, width: 1120, height: expected)
        }
    }

    func testNormalCompactAndMinimumWidthLayoutsKeepToolbarCardsAndFooterSeparate() throws {
        for width: CGFloat in [1120, 720] {
            for compact in [false, true] {
                let h = PinboardPanelHarness(); defer { h.close() }
                h.visibleFrame.size.width = width + 40
                h.panel.setPreferredHeights(normal: 330, compact: 240)
                h.panel.setCompactMode(compact)
                try h.select(h.ids[1])
                try assertLayout(h, width: width, height: compact ? 240 : 330)
            }
        }
    }

    private func assertLayout(_ h: PinboardPanelHarness, width: CGFloat, height: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let window = try XCTUnwrap(h.panel.window), root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        h.panel.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.width, width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(window.frame.height, height, accuracy: 0.5, file: file, line: line)
        let strip = try h.strip()
        let toolbar = try XCTUnwrap(h.descendants.compactMap { $0 as? NSStackView }
            .first { $0.accessibilityIdentifier() == "shelf.toolbar" })
        let search = try h.view(NSSearchField.self)
        let filters = try h.view(NSButton.self, label: "全部筛选")
        let actions = try XCTUnwrap(h.descendants.compactMap { $0 as? NSStackView }
            .first { $0.accessibilityIdentifier() == "shelf.toolbar-actions" })
        XCTAssertTrue(filters.isDescendant(of: actions), file: file, line: line)
        XCTAssertTrue(filters.isHidden, "Collapsed search keeps the toolbar quiet", file: file, line: line)
        _ = try h.menuItem("showAllFilters") // The complete filter editor stays available in overflow.
        for control in [strip, search] as [NSView] {
            XCTAssertTrue(control.isDescendant(of: toolbar), file: file, line: line)
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, file: file, line: line)
            let frame = control.convert(control.bounds, to: toolbar)
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, toolbar.bounds.maxX + 0.5, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, "\(type(of: control)) frame \(frame) outside toolbar \(toolbar.bounds)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, toolbar.bounds.maxY + 0.5, file: file, line: line)
        }
        let collection = try h.view(NSCollectionView.self, label: "剪贴板搜索结果")
        let scroll = try XCTUnwrap(collection.enclosingScrollView)
        let footer = try XCTUnwrap(try h.view(NSTextField.self, label: "结果数量与选中项").superview as? NSStackView)
        let orderedViews: [NSView] = [toolbar, scroll, footer]
        let frames = orderedViews.map { $0.convert($0.bounds, to: root) }
        for (view, frame) in zip(orderedViews, frames) {
            XCTAssertGreaterThan(frame.width, 0, "\(type(of: view)) has no width", file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, "\(type(of: view)) has no height", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, root.bounds.maxX + 0.5, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, "\(type(of: view)) frame \(frame) outside root \(root.bounds)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, root.bounds.maxY + 0.5, file: file, line: line)
        }
        for index in 0..<(frames.count - 1) {
            XCTAssertFalse(frames[index].intersects(frames[index + 1]), "Rows overlap: \(frames)", file: file, line: line)
            if root.isFlipped { XCTAssertLessThanOrEqual(frames[index].maxY, frames[index + 1].minY + 0.5, file: file, line: line) }
            else { XCTAssertGreaterThanOrEqual(frames[index].minY, frames[index + 1].maxY - 0.5, file: file, line: line) }
        }
        h.panel.perform(NSSelectorFromString("focusSearch"))
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(filters.isHiddenOrHasHiddenAncestor, file: file, line: line)
        XCTAssertGreaterThan(search.bounds.width, 100, file: file, line: line)
        for control in [toolbar, actions] as [NSView] {
            let frame = control.convert(control.bounds, to: root)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, root.bounds.maxX + 0.5, file: file, line: line)
        }
        XCTAssertFalse(toolbar.convert(toolbar.bounds, to: root).intersects(actions.convert(actions.bounds, to: root)),
                       "Expanded search must keep group navigation and overflow separate", file: file, line: line)
        let layout = try XCTUnwrap(collection.collectionViewLayout)
        layout.prepare()
        let card = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame)
        let clip = scroll.contentView.bounds
        XCTAssertGreaterThan(card.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(card.minY, clip.minY - 0.5, "Card \(card), clip \(clip)", file: file, line: line)
        XCTAssertLessThanOrEqual(card.maxY, clip.maxY + 0.5, "The card is clipped vertically: \(card), clip \(clip)", file: file, line: line)
    }
}
