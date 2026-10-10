import AppKit
import XCTest

@MainActor final class TestWindowIsolationTests: XCTestCase {
    func testChildAttachmentAndOrderingNeverExposeNativeWindows() throws {
        let parent = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        let child = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        defer {
            parent.removeChildWindow(child)
            child.orderOut(nil); parent.orderOut(nil)
        }
        parent.makeKeyAndOrderFront(nil)
        parent.addChildWindow(child, ordered: .above)
        child.makeKeyAndOrderFront(nil)
        child.orderFront(nil)
        child.orderFrontRegardless()
        child.order(.above, relativeTo: parent.windowNumber)
        XCTAssertTrue(parent.isVisible); XCTAssertTrue(child.isVisible)
        XCTAssertTrue(child.parent === parent)
        let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        let ownIDs = Set([parent.windowNumber, child.windowNumber])
        let shown = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
                && ownIDs.contains(($0[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1)
        }
        XCTAssertTrue(shown.isEmpty, "Test windows must not appear on the user's desktop")
    }
}
