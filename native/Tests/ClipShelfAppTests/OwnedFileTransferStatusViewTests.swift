import AppKit
import XCTest
@testable import ClipShelf

@MainActor
final class OwnedFileTransferStatusViewTests: XCTestCase {
    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    private func text(_ view: NSView) -> String { fields(in: view).map(\.stringValue).joined(separator: "\n") }

    func testOutstandingCountsDoNotDoubleCountFailuresAndRetryUsesCurrentState() throws {
        let view = OwnedFileTransferStatusView()
        var retries = 0; view.onRetry = { retries += 1 }
        let items: [OwnedFileTransferStatusItem] = [
            .init(filename: "first.txt", byteCount: 1, direction: .upload, failed: false, message: nil),
            .init(filename: "second.txt", byteCount: 2, direction: .download, failed: true, message: "网络暂不可用")
        ]
        view.update(items, isRunning: false, enabled: true)
        XCTAssertTrue(text(view).contains("等待上传 1，等待下载 1，其中失败 1"))
        XCTAssertTrue(text(view).contains("second.txt")); XCTAssertTrue(text(view).contains("网络暂不可用"))
        let button = try XCTUnwrap(buttons(in: view).first)
        button.performClick(nil); XCTAssertEqual(retries, 1)
        view.update(items, isRunning: true, enabled: true)
        XCTAssertFalse(button.isEnabled); button.performClick(nil); XCTAssertEqual(retries, 1)
        view.update(items, isRunning: false, enabled: false)
        XCTAssertFalse(button.isEnabled); XCTAssertFalse(text(view).contains("second.txt"))
        button.performClick(nil); XCTAssertEqual(retries, 1)
    }

    func testUnknownAndEmptyStatesNeverClaimFilesWereDownloaded() throws {
        let view = OwnedFileTransferStatusView()
        view.unavailable("账号已改变", isRunning: false, enabled: true)
        XCTAssertTrue(text(view).contains("无法读取")); XCTAssertFalse(text(view).contains("已同步"))
        XCTAssertTrue(try XCTUnwrap(buttons(in: view).first).isEnabled)
        view.update([], isRunning: false, enabled: true)
        XCTAssertTrue(text(view).contains("没有待处理"))
        XCTAssertTrue(text(view).contains("普通文件引用不会自动上传"))
        XCTAssertFalse(try XCTUnwrap(buttons(in: view).first).isEnabled)
    }

    func testLongQueueScrollsWithoutMovingRetryOutsideCompactView() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = OwnedFileTransferStatusView(frame: .init(x: 0, y: 0, width: 340, height: 180))
        window.contentView = view
        view.update((0..<100).map { .init(filename: "长文件名-\($0)-" + String(repeating: "内容", count: 30),
                                         byteCount: 64 * 1_024 * 1_024, direction: .download, failed: true,
                                         message: "下载失败，可重试") }, isRunning: false, enabled: true)
        view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(buttons(in: view).first)
        XCTAssertTrue(view.bounds.contains(button.frame))
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
        XCTAssertTrue(text(view).contains("长文件名-99-"))
    }
}
