import AppKit
import ClipShelfCore
import ClipShelfLocalization
import XCTest
@testable import ClipShelf

@MainActor
final class PinboardTabStripTests: XCTestCase {
    private var windows: [UnshownTestPanel] = []
    private func event(_ type: NSEvent.EventType, point: NSPoint = NSPoint(x: 20, y: 12)) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func fixture(_ count: Int = 4, direction: NSUserInterfaceLayoutDirection = .leftToRight,
                         width: CGFloat = 850) -> (PinboardTabStrip, [Pinboard]) {
        let strip = PinboardTabStrip(layoutDirection: direction)
        strip.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        let window = UnshownTestPanel(contentRect: strip.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = strip
        windows.append(window)
        let boards = (0..<count).map { Pinboard(name: "Board \($0)") }
        strip.onReorder = { _, _ in }
        strip.setPinboards(boards, selectedID: boards.first?.id)
        strip.layoutSubtreeIfNeeded()
        return (strip, boards)
    }

    private func endPoint(_ strip: PinboardTabStrip) throws -> NSPoint {
        let last = try XCTUnwrap(strip.tabButtons.last)
        return NSPoint(x: strip.userInterfaceLayoutDirection == .rightToLeft ? last.frame.minX : last.frame.maxX, y: 12)
    }

    func testClickSelectsByIdentityAndAllContentIsFixed() throws {
        let (strip, boards) = fixture()
        var selections: [UUID?] = []
        strip.onSelect = { selections.append($0) }
        let target = strip.tabButtons[2]
        strip.window?.makeKeyAndOrderFront(nil)
        let center = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        target.mouseDown(with: event(.leftMouseDown, point: center))
        XCTAssertTrue(selections.isEmpty, "Beginning a potential drag must not navigate")
        target.mouseUp(with: event(.leftMouseUp, point: center))
        XCTAssertEqual(selections, [boards[2].id])
        strip.allButton.performClick(nil)
        XCTAssertEqual(selections, [boards[2].id, nil])
        XCTAssertFalse(strip.allButton is PinboardTabButton)
        XCTAssertEqual(strip.pinboards.map(\.id), boards.map(\.id))
    }

    func testSameNameBoardsKeepDistinctIdentityAndSelectedState() {
        let strip = PinboardTabStrip()
        let boards = [Pinboard(name: "Same"), Pinboard(name: "Same")]
        strip.setPinboards(boards, selectedID: boards[1].id)
        XCTAssertEqual(strip.tabButtons.map(\.boardID), boards.map(\.id))
        XCTAssertEqual(strip.tabButtons.map(\.state), [.off, .on])
        XCTAssertEqual(strip.allButton.state, .off)
        strip.setPinboards([boards[0]], selectedID: boards[1].id)
        XCTAssertNil(strip.selectedID)
        XCTAssertEqual(strip.allButton.state, .on)
    }

    func testExplicitSingleAndMultipleBoardFiltersHighlightTheirActualScope() {
        let (strip, boards) = fixture()
        strip.setPinboards(boards, selectedIDs: [boards[2].id])
        XCTAssertEqual(strip.selectedIDs, [boards[2].id])
        XCTAssertEqual(strip.selectedID, boards[2].id)
        XCTAssertEqual(strip.tabButtons.map(\.state), [.off, .off, .on, .off])
        XCTAssertEqual(strip.allButton.state, .off)
        strip.setPinboards(boards, selectedIDs: [boards[1].id, boards[3].id])
        XCTAssertEqual(strip.selectedIDs, [boards[1].id, boards[3].id])
        XCTAssertNil(strip.selectedID)
        XCTAssertEqual(strip.tabButtons.map(\.state), [.off, .on, .off, .on])
        XCTAssertEqual(strip.allButton.state, .off, "Multiple boards are not the unrestricted history")
        strip.setPinboards(boards, selectedIDs: [])
        XCTAssertTrue(strip.selectedIDs.isEmpty)
        XCTAssertEqual(strip.tabButtons.map(\.state), [.off, .off, .off, .off])
        XCTAssertEqual(strip.allButton.state, .on)
    }

    func testMultipleBoardFilterKeepsScrollPositionAndDropsOnlyMissingSelections() {
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            let (strip, boards) = fixture(25, direction: direction, width: 390)
            let clip = strip.scrollView.contentView
            clip.scroll(to: NSPoint(x: 400, y: 0))
            strip.scrollView.reflectScrolledClipView(clip)
            let position = clip.bounds.origin
            strip.setPinboards(boards, selectedIDs: [boards[0].id, boards[24].id])
            strip.layoutSubtreeIfNeeded()
            XCTAssertEqual(clip.bounds.origin, position)
            XCTAssertEqual(strip.allButton.state, .off)
            strip.setPinboards(Array(boards.dropLast()), selectedIDs: [boards[0].id, boards[24].id])
            XCTAssertEqual(strip.selectedIDs, [boards[0].id])
            XCTAssertEqual(strip.tabButtons.first?.state, .on)
            XCTAssertEqual(strip.allButton.state, .off)
        }
    }

    func testDragKeepsPendingMultipleSelectionAndLatestMetadataAfterEnd() throws {
        let (strip, boards) = fixture()
        strip.setPinboards(boards, selectedIDs: [boards[0].id, boards[1].id])
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        var renamed = boards
        renamed[2].name = "Latest board name"
        strip.setPinboards(renamed, selectedIDs: [boards[2].id, boards[3].id])
        XCTAssertEqual(strip.selectedIDs, [boards[0].id, boards[1].id])
        XCTAssertEqual(strip.tabButtons.map(\.state), [.on, .on, .off, .off])
        XCTAssertEqual(strip.allButton.state, .off)
        XCTAssertTrue(strip.acceptDrop(at: try endPoint(strip), source: source))
        strip.cancelDrag()
        XCTAssertEqual(strip.selectedIDs, [boards[2].id, boards[3].id])
        XCTAssertEqual(strip.tabButtons.map(\.state), [.off, .off, .on, .on])
        XCTAssertEqual(strip.tabButtons[2].title, renamed[2].name)
        XCTAssertEqual(strip.allButton.state, .off)
    }

    func testDragUsesWholeSnapshotAndCommitsOnlyOnceWithoutNavigating() throws {
        let (strip, boards) = fixture()
        var calls: [([UUID], [UUID])] = []
        var selections = 0
        strip.onReorder = { calls.append(($0, $1)) }
        strip.onSelect = { _ in selections += 1 }
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        source.mouseDragged(with: event(.leftMouseDragged, point: NSPoint(x: 45, y: 12)))
        XCTAssertEqual(strip.updateDrag(at: try endPoint(strip), source: source), .move)
        XCTAssertTrue(strip.isShowingInsertion)
        XCTAssertTrue(strip.acceptDrop(at: try endPoint(strip), source: source))
        XCTAssertFalse(strip.acceptDrop(at: try endPoint(strip), source: source))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, [boards[1].id, boards[2].id, boards[3].id, boards[0].id])
        XCTAssertEqual(calls.first?.1, boards.map(\.id))
        XCTAssertEqual(strip.pinboards.map(\.id), boards.map(\.id), "A gesture is not a storage receipt")
        source.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(selections, 0)
        XCTAssertNil(strip.activeDragID)
    }

    func testStaleAndForeignSourcesCannotReorderDespiteValidBoardIdentity() throws {
        let (strip, _) = fixture()
        let (other, _) = fixture()
        var calls = 0
        strip.onReorder = { _, _ in calls += 1 }
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        let foreign = other.tabButtons[0]
        foreign.mouseDown(with: event(.leftMouseDown))
        XCTAssertEqual(strip.updateDrag(at: try endPoint(strip), source: foreign), [])
        XCTAssertFalse(strip.acceptDrop(at: try endPoint(strip), source: foreign))
        XCTAssertFalse(strip.acceptDrop(at: try endPoint(strip), source: nil))
        strip.cancelDrag()
        XCTAssertFalse(strip.acceptDrop(at: try endPoint(strip), source: source))
        XCTAssertEqual(calls, 0)
        other.cancelDrag()
    }

    func testExternalMaskIsEmptyAndCancelledGestureCannotRestart() {
        let (strip, _) = fixture()
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        XCTAssertEqual(source.dragOperationMask(for: .withinApplication), .move)
        XCTAssertEqual(source.dragOperationMask(for: .outsideApplication), [])
        source.cancelOperation(nil)
        source.mouseDragged(with: event(.leftMouseDragged, point: NSPoint(x: 70, y: 12)))
        XCTAssertNil(source.gestureID)
        XCTAssertNil(strip.activeDragID)
        XCTAssertEqual(source.dragOperationMask(for: .withinApplication), [])
    }

    func testBackgroundReorderFreezesFramesAndRejectsDropThenInstallsLatest() throws {
        let (strip, boards) = fixture()
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        XCTAssertNotNil(strip.activeDragID)
        // beginGesture settles native control layout before freezing its hit targets.
        // Measure that actual gesture, not the earlier provisional fitting-size pass.
        let frames = strip.tabButtons.map(\.frame)
        strip.needsLayout = true
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.tabButtons.map(\.frame), frames)
        strip.setPinboards(Array(boards.reversed()), selectedID: boards[2].id)
        strip.frame.size.width = 550
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.tabButtons.map(\.frame), frames)
        XCTAssertEqual(strip.pinboards.map(\.id), boards.map(\.id))
        XCTAssertEqual(strip.updateDrag(at: try endPoint(strip), source: source), [])
        XCTAssertFalse(strip.acceptDrop(at: try endPoint(strip), source: source))
        strip.cancelDrag()
        XCTAssertEqual(strip.pinboards.map(\.id), boards.reversed().map(\.id))
        XCTAssertEqual(strip.selectedID, boards[2].id)
    }

    func testBackgroundAddAndDeleteRejectFrozenOrder() throws {
        for adding in [false, true] {
            let (strip, boards) = fixture()
            let source = strip.tabButtons[0]
            source.mouseDown(with: event(.leftMouseDown))
            let updated = adding ? boards + [Pinboard(name: "New")] : Array(boards.dropLast())
            strip.setPinboards(updated, selectedID: nil)
            XCTAssertFalse(strip.acceptDrop(at: try endPoint(strip), source: source))
            strip.cancelDrag()
            XCTAssertEqual(strip.pinboards.map(\.id), updated.map(\.id))
        }
    }

    func testBackgroundMetadataDoesNotInvalidateIdentityOrLoseLatestNames() throws {
        let (strip, boards) = fixture()
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        var updated = boards
        updated[1].name = "Renamed while dragging"
        updated[1].color = "#FF0000"
        strip.setPinboards(updated, selectedID: boards[3].id)
        XCTAssertEqual(strip.tabButtons[1].title, boards[1].name)
        XCTAssertTrue(strip.acceptDrop(at: try endPoint(strip), source: source))
        strip.cancelDrag()
        XCTAssertEqual(strip.tabButtons[1].title, updated[1].name)
        XCTAssertEqual(strip.pinboards[1].color, updated[1].color)
        XCTAssertEqual(strip.selectedID, boards[3].id)
    }

    func testSavingCancelsGestureAndDisablesNewDragsButAllowsNavigation() throws {
        let (strip, boards) = fixture()
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        strip.isSaving = true
        XCTAssertNil(strip.activeDragID)
        source.mouseDown(with: event(.leftMouseDown))
        XCTAssertNil(strip.activeDragID)
        XCTAssertFalse(strip.acceptDrop(at: try endPoint(strip), source: source))
        var chosen: UUID?
        strip.onSelect = { chosen = $0 }
        strip.window?.makeKeyAndOrderFront(nil)
        let center = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        source.mouseUp(with: event(.leftMouseUp, point: center))
        XCTAssertEqual(chosen, boards[0].id)
        strip.isSaving = false
        source.mouseDown(with: event(.leftMouseDown))
        XCTAssertNotNil(strip.activeDragID)
        strip.cancelDrag()
    }

    func testSynchronousSavingCallbackCannotSubmitTwiceOrLoseCommittedOrder() throws {
        let (strip, boards) = fixture()
        var calls = 0
        strip.onReorder = { ids, _ in
            calls += 1
            strip.isSaving = true
            strip.setPinboards(ids.compactMap { id in boards.first { $0.id == id } }, selectedID: boards[1].id)
            strip.isSaving = false
        }
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        let oldGesture = strip.activeDragID
        let point = try endPoint(strip)
        XCTAssertTrue(strip.acceptDrop(at: point, source: source))
        XCTAssertFalse(strip.acceptDrop(at: point, source: source))
        strip.endGesture(oldGesture)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(strip.pinboards.map(\.id), [boards[1].id, boards[2].id, boards[3].id, boards[0].id])
        XCTAssertEqual(strip.selectedID, boards[1].id)
    }

    func testLogicalInsertionAgreesWithPhysicalMirroredFrames() throws {
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            let (strip, boards) = fixture(direction: direction)
            let frames = strip.tabButtons.map(\.frame)
            XCTAssertEqual(frames[0].midX < frames[1].midX, direction == .leftToRight)
            XCTAssertEqual(strip.allButton.frame.midX < strip.scrollView.frame.midX, direction == .leftToRight)
            var saved: [UUID]?
            strip.onReorder = { saved = $0; _ = $1 }
            let source = strip.tabButtons[3]
            source.mouseDown(with: event(.leftMouseDown))
            let first = frames[0]
            let point = NSPoint(x: direction == .leftToRight ? first.minX : first.maxX, y: 12)
            XCTAssertEqual(strip.updateDrag(at: point, source: source), .move)
            XCTAssertTrue(strip.isShowingInsertion)
            XCTAssertTrue(strip.acceptDrop(at: point, source: source))
            XCTAssertEqual(saved, [boards[3].id, boards[0].id, boards[1].id, boards[2].id])
            strip.cancelDrag()
        }
    }

    func testLongTitlesRetainAccessibleNamesAndSelectedOffscreenTabIsRevealed() throws {
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            let (strip, boards) = fixture(25, direction: direction, width: 390)
            var renamed = boards
            renamed[20].name = String(repeating: "Long 中文 שלום ", count: 30)
            strip.setPinboards(renamed, selectedID: renamed[20].id)
            strip.layoutSubtreeIfNeeded()
            let selected = strip.tabButtons[20]
            XCTAssertLessThanOrEqual(selected.frame.width, 240)
            XCTAssertEqual(selected.accessibilityLabel(), renamed[20].name)
            XCTAssertEqual(selected.toolTip, renamed[20].name)
            let viewport = strip.scrollView.contentView.bounds
            XCTAssertGreaterThanOrEqual(selected.frame.minX, viewport.minX)
            XCTAssertLessThanOrEqual(selected.frame.maxX, viewport.maxX)
        }
    }

    func testEdgeScrollReachesHiddenDestinationAndStopsAfterExit() throws {
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            let (strip, boards) = fixture(30, direction: direction, width: 410)
            let source = strip.tabButtons[0]
            var saved: [UUID]?
            strip.onReorder = { saved = $0; _ = $1 }
            source.mouseDown(with: event(.leftMouseDown))
            let clip = strip.scrollView.contentView
            let initial = clip.bounds.minX
            let viewportX: CGFloat = direction == .leftToRight ? clip.bounds.width - 1 : 1
            _ = strip.updateDrag(at: NSPoint(x: initial + viewportX, y: 12), source: source)
            for _ in 0..<25 { strip.advanceEdgeScrolling() }
            XCTAssertEqual(clip.bounds.minX > initial, direction == .leftToRight)
            XCTAssertNotEqual(clip.bounds.minX, initial)
            let position = clip.bounds.minX
            strip.clearInsertion()
            strip.advanceEdgeScrolling()
            XCTAssertEqual(clip.bounds.minX, position)
            XCTAssertFalse(strip.isShowingInsertion)
            XCTAssertTrue(strip.acceptDrop(at: NSPoint(x: position + viewportX, y: 12), source: source))
            let ids = try XCTUnwrap(saved)
            XCTAssertGreaterThan(try XCTUnwrap(ids.firstIndex(of: boards[0].id)), 1)
            XCTAssertEqual(ids.filter { $0 != boards[0].id }, boards.dropFirst().map(\.id))
            strip.cancelDrag()
            XCTAssertEqual(strip.pinboards.map(\.id), boards.map(\.id))
        }
    }

    func testEdgeScrollPhysicalDirectionsAndBounds() {
        XCTAssertLessThan(PinboardTabStrip.edgeScrollDelta(pointerX: 0, viewportWidth: 200), 0)
        XCTAssertGreaterThan(PinboardTabStrip.edgeScrollDelta(pointerX: 200, viewportWidth: 200), 0)
        XCTAssertEqual(PinboardTabStrip.edgeScrollDelta(pointerX: 100, viewportWidth: 200), 0)
        XCTAssertEqual(PinboardTabStrip.edgeScrollDelta(pointerX: -1, viewportWidth: 200), 0)
        XCTAssertEqual(PinboardTabStrip.edgeScrollDelta(pointerX: 201, viewportWidth: 200), 0)
        XCTAssertEqual(PinboardTabStrip.edgeScrollDelta(pointerX: 0, viewportWidth: 0), 0)
    }

    func testDirectionChangeAndWindowRemovalInvalidatePreparedGesture() {
        let (strip, _) = fixture()
        let source = strip.tabButtons[0]
        source.mouseDown(with: event(.leftMouseDown))
        InterfaceLayout.apply(to: strip, direction: .rightToLeft)
        strip.needsLayout = true
        strip.layoutSubtreeIfNeeded()
        XCTAssertNil(strip.activeDragID)
        source.mouseDown(with: event(.leftMouseDown))
        strip.viewWillMove(toWindow: NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false))
        XCTAssertNil(strip.activeDragID)
    }

    func testReleasingOutsideHiddenOrCancelledButtonDoesNotNavigate() {
        for mode in 0..<4 {
            let (strip, _) = fixture()
            strip.window?.makeKeyAndOrderFront(nil)
            let source = strip.tabButtons[0]
            let center = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            let outside = source.convert(NSPoint(x: source.bounds.maxX + 8, y: source.bounds.midY), to: nil)
            var selections = 0
            strip.onSelect = { _ in selections += 1 }
            if mode == 3 { strip.isSaving = true }
            source.mouseDown(with: event(.leftMouseDown, point: center))
            if mode == 1 { strip.window?.orderOut(nil) }
            if mode == 2 { source.cancelOperation(nil) }
            source.mouseUp(with: event(.leftMouseUp, point: mode == 0 || mode == 3 ? outside : center))
            XCTAssertEqual(selections, 0, "mode \(mode)")
            XCTAssertNil(strip.activeDragID)
        }
    }
}
