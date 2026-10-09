import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

final class PanelDeviceFilterTests: XCTestCase {
    @MainActor private func popup(_ panel: ClipboardPanelController, label: String) throws -> NSPopUpButton {
        func find(_ view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton, popup.accessibilityLabel() == label { return popup }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(panel.window?.contentView.flatMap(find))
    }

    @MainActor func testDeletedDeviceCandidateRemainsAnExplicitFilter() throws {
        let localID = UUID(), remoteID = UUID()
        let panel = ClipboardPanelController()
        var requests: [PanelPageRequest] = []
        panel.onPageRequest = { request, _ in requests.append(request) }
        panel.setDevices([ClipboardOriginDevice(id: localID), ClipboardOriginDevice(id: remoteID)], localDeviceID: localID)
        let filter = try popup(panel, label: "按最初采集设备筛选")
        filter.select(try XCTUnwrap(filter.itemArray.first { $0.representedObject as? String == remoteID.uuidString }))
        panel.perform(NSSelectorFromString("deviceChanged"))
        guard case .device(let selected) = try XCTUnwrap(requests.last).query.deviceFilter else { return XCTFail("Expected explicit device condition") }
        XCTAssertEqual(selected, remoteID)
        panel.setDevices([], localDeviceID: localID)
        XCTAssertEqual(filter.selectedItem?.representedObject as? String, remoteID.uuidString)
        XCTAssertTrue(filter.itemArray.contains { $0.title == "此 Mac" && $0.isEnabled })
        XCTAssertTrue(filter.itemArray.contains { $0.representedObject as? String == "unknown" })
        XCTAssertTrue(filter.selectedItem?.title.contains(String(remoteID.uuidString.prefix(8))) == true)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testTextAndBoardNavigationPreserveDeviceButClearResetsIt() throws {
        let localID = UUID(), board = Pinboard(name: "Synthetic")
        let panel = ClipboardPanelController()
        var requests: [PanelPageRequest] = []
        panel.onPageRequest = { request, _ in requests.append(request) }
        panel.setDevices([], localDeviceID: localID)
        panel.setPinboards([board])
        let device = try popup(panel, label: "按最初采集设备筛选")
        device.select(try XCTUnwrap(device.itemArray.first { $0.representedObject as? String == "unknown" }))
        panel.perform(NSSelectorFromString("deviceChanged"))
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        guard case .unknown = try XCTUnwrap(requests.last).query.deviceFilter else { return XCTFail("Text search must preserve the explicit device condition") }
        let boards = try popup(panel, label: "分组")
        boards.selectItem(at: 1)
        panel.perform(NSSelectorFromString("boardChanged"))
        let scoped = try XCTUnwrap(requests.last)
        XCTAssertEqual(scoped.query.pinboardIDs, [board.id])
        guard case .unknown = scoped.query.deviceFilter else { return XCTFail("Board navigation must preserve device condition") }
        panel.perform(NSSelectorFromString("clearFilters"))
        let cleared = try XCTUnwrap(requests.last)
        guard case .all = cleared.query.deviceFilter else { return XCTFail("Clear must reset device condition") }
        XCTAssertTrue(cleared.query.pinboardIDs.isEmpty)
        XCTAssertEqual(cleared.offset, 0)
        XCTAssertEqual(cleared.query.limit, PanelPageWindow.size)
        XCTAssertFalse(panel.isVisible)
    }
}
