import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore
@testable import ClipShelfLocalization

/// Actual delivered captions on unshown application controls. This catches
/// compression and geometry regressions, not native-speaker or screen-reader QA.
@MainActor final class MultilingualLayoutTests: XCTestCase {
    private func eachLanguage(_ body: (LocalizationRuntime, NSUserInterfaceLayoutDirection, String) throws -> Void) throws {
        for language in InterfaceLanguage.supported {
            let runtime = LocalizationRuntime()
            runtime.configure(language: language, preferredLanguages: [language.rawValue], hostBundle: Bundle(for: Self.self))
            XCTAssertEqual(runtime.diagnostics.issues, [], language.rawValue)
            try body(runtime, language.isRightToLeft ? .rightToLeft : .leftToRight, language.rawValue)
        }
    }

    func testStackActionsFitAndFollowInterfaceDirectionInEveryLanguage() throws {
        try eachLanguage { runtime, direction, language in
            let controller = StackPanelController()
            let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
            let restore = try button("restorePrevious", in: content), reverse = try button("reverse", in: content)
            let end = try button("endSession", in: content)
            restore.title = runtime.text("恢复上一项"); reverse.title = runtime.text("反序 ↑"); end.title = runtime.text("结束")
            let summary = try XCTUnwrap(all(NSTextField.self, in: content).first)
            summary.stringValue = runtime.text("复制内容加入队列，在目标 App 按 ⌘V 逐项粘贴。")
            InterfaceLayout.apply(to: content, direction: direction); content.layoutSubtreeIfNeeded()
            for action in [restore, reverse, end] { assertFits(action, in: content, context: language) }
            let needed = try XCTUnwrap(summary.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: summary.bounds.width, height: .greatestFiniteMagnitude))
            XCTAssertGreaterThanOrEqual(summary.bounds.height + 0.5, needed.height, language)
            XCTAssertTrue(content.bounds.contains(summary.convert(summary.bounds, to: content)),
                          "\(language): summary=\(summary.convert(summary.bounds, to: content)), content=\(content.bounds)")
            XCTAssertEqual(reverse.convert(reverse.bounds, to: content).midX < end.convert(end.bounds, to: content).midX,
                           direction == .leftToRight, language)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testFilterActionsAndDateControlsFitInEveryLanguage() throws {
        try eachLanguage { runtime, direction, language in
            let controller = HistoryFilterController(query: HistoryQuery(),
                options: .init(pinboards: [], sources: [:], devices: [:], localDeviceID: nil))
            let window = NSPanel(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = controller.view
            let clear = try button("clearDraft", in: controller.view), cancel = try button("cancelDraft", in: controller.view)
            let apply = try button("applyDraft", in: controller.view)
            clear.title = runtime.text("清除筛选"); cancel.title = runtime.text("取消"); apply.title = runtime.text("应用筛选")
            let dates = all(NSButton.self, in: controller.view).filter { $0.action.map(NSStringFromSelector) == "datesChanged" }
            XCTAssertEqual(dates.count, 2)
            dates[0].title = runtime.text("开始（含）"); dates[1].title = runtime.text("结束（含）")
            InterfaceLayout.apply(to: controller.view, direction: direction); controller.view.layoutSubtreeIfNeeded()
            for action in [clear, cancel, apply] + dates { assertFits(action, in: controller.view, context: language) }
            for picker in all(NSDatePicker.self, in: controller.view) {
                XCTAssertTrue(controller.view.bounds.contains(picker.convert(picker.bounds, to: controller.view)), language)
            }
            XCTAssertFalse(window.isVisible)
        }
    }

    func testPinboardFilterActionsFitInEveryLanguage() throws {
        try eachLanguage { runtime, direction, language in
            let controller = PinboardFilterController(boards: [], selected: [])
            let window = NSPanel(contentRect: controller.view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = controller.view
            let clear = try button("clearSelection", in: controller.view), cancel = try button("cancelSelection", in: controller.view)
            let apply = try button("applySelection", in: controller.view)
            clear.title = runtime.text("取消勾选"); cancel.title = runtime.text("取消"); apply.title = runtime.text("应用筛选")
            InterfaceLayout.apply(to: controller.view, direction: direction); controller.view.layoutSubtreeIfNeeded()
            for action in [clear, cancel, apply] { assertFits(action, in: controller.view, context: language) }
            XCTAssertFalse(window.isVisible)
        }
    }

    func testUploadConsentRetainsEveryTranslatedLineAndStaysOptIn() throws {
        try eachLanguage { runtime, direction, language in
            let title = runtime.text("同时上传此前未归属其他账号的本地历史与分组")
            let choice = CloudSyncSettingsController.makeLocalHistoryUploadChoice(title: title)
            InterfaceLayout.apply(to: choice, direction: direction)
            let cell = try XCTUnwrap(choice.cell)
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: choice.bounds.width, height: .greatestFiniteMagnitude))
            XCTAssertEqual(choice.title, title); XCTAssertEqual(choice.state, .off)
            XCTAssertTrue(cell.wraps); XCTAssertEqual(cell.lineBreakMode, .byWordWrapping)
            XCTAssertGreaterThanOrEqual(choice.bounds.height, needed.height, language)
        }
    }

    func testLanguageSettingActionsFitWithoutSavingPreferences() throws {
        let suite = "clipshelf-layout-tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        try eachLanguage { runtime, direction, language in
            let controller = LanguageSettingsController(preferences: .init(preferences: preferences, allowsChanges: false))
            let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
            let save = try button("saveSelection", in: content), close = try button("closeSettings", in: content)
            save.title = runtime.text("保存语言设置"); close.title = runtime.text("关闭")
            InterfaceLayout.apply(to: content, direction: direction); content.layoutSubtreeIfNeeded()
            for action in [save, close] { assertFits(action, in: content, context: language) }
            XCTAssertFalse(save.isEnabled); XCTAssertFalse(window.isVisible)
        }
        XCTAssertTrue((preferences.persistentDomain(forName: suite) ?? [:]).isEmpty)
    }

    private func button(_ action: String, in root: NSView) throws -> NSButton {
        try XCTUnwrap(all(NSButton.self, in: root).first { $0.action.map(NSStringFromSelector) == action })
    }
    private func all<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { all(type, in: $0) }
    }
    private func assertFits(_ button: NSButton, in root: NSView, context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(button.bounds.width + 0.5, button.fittingSize.width,
                                   "\(context): \(button.title)", file: file, line: line)
        XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)),
                      "\(context): \(button.title)", file: file, line: line)
    }
}
