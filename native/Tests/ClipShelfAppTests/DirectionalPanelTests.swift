import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore
import ClipShelfLocalization

@MainActor final class DirectionalPanelTests: XCTestCase {
    private func selected(_ h: PanelCallbackHarness) -> [ClipboardSelectionReference] {
        var result: [ClipboardSelectionReference] = []
        h.panel.resolveSelection = { refs, _ in result = refs }
        h.key(8, characters: "c", flags: .command)
        return result
    }

    func testRTLPhysicalArrowsAndShiftFollowMirroredCardsWithoutChangingLogicalOrder() throws {
        let h = try PanelCallbackHarness(layoutDirection: .rightToLeft); defer { h.close() }
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        XCTAssertEqual(selected(h), [all[600]])
        h.key(123); XCTAssertEqual(selected(h), [all[601]])
        h.key(124); XCTAssertEqual(selected(h), [all[600]])
        h.key(123, flags: .shift); XCTAssertEqual(selected(h), Array(all[600...601]))
        h.key(124, flags: .shift); XCTAssertEqual(selected(h), [all[600]])
        XCTAssertEqual(try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references, all)
    }

    func testRTLBoundaryRequestsKeepLogicalFirstAndLastAndMoveAcrossPages() throws {
        let h = try PanelCallbackHarness(layoutDirection: .rightToLeft); defer { h.close() }
        h.key(126, flags: .command)
        XCTAssertEqual(h.requests.last?.0.boundary, .first)
        try h.completeLastPage()
        let before = h.requests.count
        h.key(124) // Beyond the first logical item, not toward the second page.
        XCTAssertEqual(h.requests.count, before)
        h.key(125, flags: .command)
        XCTAssertEqual(h.requests.last?.0.boundary, .last)
        try h.completeLastPage()
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        XCTAssertEqual(selected(h), [try XCTUnwrap(all.last)])
    }

    func testOrderingKeysAndMenusAgreeInBothDirections() throws {
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            for key: UInt16 in [123, 124] {
                let h = try PanelCallbackHarness(layoutDirection: direction); defer { h.close() }
                let forward = (key == 124) == (direction == .leftToRight)
                var received: Bool?
                h.panel.onStepSelection = { _, _, value, _ in received = value }
                h.key(key, flags: [.command, .option])
                XCTAssertEqual(received, forward)
                let menus = descendants(try XCTUnwrap(h.panel.window?.contentView)).compactMap { ($0 as? NSPopUpButton)?.menu }
                let earlier = try XCTUnwrap(menus.flatMap(\.items).first { $0.action.map(NSStringFromSelector) == "moveItemsEarlier" })
                let later = try XCTUnwrap(menus.flatMap(\.items).first { $0.action.map(NSStringFromSelector) == "moveItemsLater" })
                XCTAssertEqual(earlier.keyEquivalent, direction == .rightToLeft ? "\u{F703}" : "\u{F702}")
                XCTAssertEqual(later.keyEquivalent, direction == .rightToLeft ? "\u{F702}" : "\u{F703}")
            }
        }
    }

    func testActualFlowLayoutAndInsertionGeometryAgreeForRTLAndLTR() throws {
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            let h = try PanelCallbackHarness(layoutDirection: direction); defer { h.close() }
            let collection: NSCollectionView = try h.view(label: "剪贴板搜索结果")
            h.panel.window?.contentView?.layoutSubtreeIfNeeded()
            let layout = try XCTUnwrap(collection.collectionViewLayout)
            layout.prepare()
            let frames = try (0..<3).map { try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame) }
            XCTAssertEqual(collection.userInterfaceLayoutDirection, direction)
            XCTAssertEqual(frames[0].midX < frames[1].midX, direction == .leftToRight)
            for index in frames.indices {
                let before = direction == .leftToRight ? frames[index].minX : frames[index].maxX
                XCTAssertEqual(PanelLayoutDirection.insertionIndex(at: before, frames: frames, direction: direction), index)
                let line = PanelLayoutDirection.insertionLineX(frame: frames[index], before: true, direction: direction)
                XCTAssertEqual(line < frames[index].minX, direction == .leftToRight)
            }
            let last = try XCTUnwrap(frames.last)
            let after = direction == .leftToRight ? last.maxX + 10 : last.minX - 10
            XCTAssertEqual(PanelLayoutDirection.insertionIndex(at: after, frames: frames, direction: direction), frames.count)
            let finalFrame = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: collection.numberOfItems(inSection: 0) - 1, section: 0))?.frame)
            for (frame, before) in [(frames[0], true), (finalFrame, false)] {
                let line = PanelLayoutDirection.insertionLineFrame(frame: frame, before: before, direction: direction,
                                                                   contentWidth: collection.bounds.width)
                XCTAssertGreaterThanOrEqual(line.minX, 0)
                XCTAssertLessThanOrEqual(line.maxX, collection.bounds.width)
                XCTAssertEqual(line.width, 3)
            }
        }
    }

    func testExplicitDirectionReachesOwnedDescendantsWithoutChangingUserContentOrParagraphStyle() throws {
        let root = NSView(), stack = NSStackView(), field = NSTextField(string: "ABC / שלום / 中文"), text = NSTextView()
        let content = "https://example.invalid/a?b=1\nlet x = 12; // שלום"
        text.string = content
        let before = text.attributedString()
        stack.addArrangedSubview(field); stack.addArrangedSubview(text); root.addSubview(stack)
        for direction in [NSUserInterfaceLayoutDirection.rightToLeft, .leftToRight] {
            InterfaceLayout.apply(to: root, direction: direction)
            XCTAssertTrue(descendants(root).allSatisfy { $0.userInterfaceLayoutDirection == direction })
            XCTAssertEqual(field.stringValue, "ABC / שלום / 中文")
            XCTAssertEqual(text.attributedString(), before)
            XCTAssertEqual(text.string, content)
        }
    }

    func testFilterRebuildKeepsRTLAndBoardIdentity() throws {
        let board = Pinboard(name: "Mixed ABC / שלום")
        let controller = HistoryFilterController(query: HistoryQuery(pinboardIDs: [board.id]),
            options: .init(pinboards: [board], sources: [:], devices: [:], localDeviceID: nil))
        InterfaceLayout.apply(to: controller.view, direction: .rightToLeft)
        var renamed = board
        renamed.name = "Renamed / שלום"
        controller.updateOptions(.init(pinboards: [renamed], sources: [:], devices: [:], localDeviceID: nil))
        let choice = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == renamed.name })
        XCTAssertEqual(choice.userInterfaceLayoutDirection, .rightToLeft)
        XCTAssertEqual(choice.state, .on)
        XCTAssertEqual(controller.draft.query.pinboardIDs, [board.id])
        XCTAssertEqual(choice.title, renamed.name)
    }

    func testInitialInlineResultsRevealFirstLogicalCardInBothDirections() throws {
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            let controller = ClipboardPanelController(layoutDirection: direction)
            let root = try XCTUnwrap(controller.window?.contentView)
            root.layoutSubtreeIfNeeded()
            controller.update(records: (0..<12).map { ClipboardRecord(text: "Synthetic \($0)") })
            let collection = try XCTUnwrap(descendants(root).compactMap { $0 as? NSCollectionView }.first)
            let layout = try XCTUnwrap(collection.collectionViewLayout)
            let first = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame)
            let visible = try XCTUnwrap(collection.enclosingScrollView).contentView.bounds
            XCTAssertGreaterThanOrEqual(first.minX, visible.minX, "\(direction): \(first), \(visible)")
            XCTAssertLessThanOrEqual(first.maxX, visible.maxX, "\(direction): \(first), \(visible)")
            XCTAssertFalse(controller.window?.isVisible ?? true)
        }
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
}
