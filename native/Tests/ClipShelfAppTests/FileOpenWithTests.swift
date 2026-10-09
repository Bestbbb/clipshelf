import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class OpenWithHarness {
    let controller: FileReferencePreviewController
    let initial: ClipboardFileRepairSnapshot
    let app = URL(fileURLWithPath: "/Applications/Synthetic Reader.app")
    var reads: [FileReferencePreviewController.SnapshotReply] = []
    var discoveries: [(URL, (Result<FileApplicationListing, Error>) -> Void)] = []
    var launches: [(URL, URL, (Result<Void, Error>) -> Void)] = []
    var menus: [(NSMenu, () -> Void)] = []
    var picks: [(URL?) -> Void] = []
    var cancelledMenus = 0, cancelledPickers = 0
    var context = true
    init(readOnly: Bool = false) {
        initial = Self.fixture(readOnly: readOnly)
        var discover: FileApplicationOpener.Provider!
        var launch: FileApplicationOpener.Launcher!
        var menu: FileReferencePreviewController.ApplicationMenuPresenter!
        var pick: FileReferencePreviewController.ApplicationPicker!
        let service = FileApplicationOpener(provider: { discover($0, $1) }, launcher: { launch($0, $1, $2) },
            applicationName: { $0.deletingPathExtension().lastPathComponent }, isApplication: { $0.pathExtension == "app" })
        controller = FileReferencePreviewController(record: initial.record,
            window: UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: .borderless, backing: .buffered, defer: false),
            openURL: { _ in XCTFail("Default opener should not run"); return false },
            applicationOpener: service, chooseApplication: { pick($0, $1) }, presentApplicationMenu: { menu($0, $1, $2) })
        discover = { [weak self] file, reply in self?.discoveries.append((file, reply)) }
        launch = { [weak self] file, app, reply in self?.launches.append((file, app, reply)) }
        menu = { [weak self] menu, _, close in
            self?.menus.append((menu, close))
            return { [weak self] in self?.cancelledMenus += 1; close() }
        }
        pick = { [weak self] _, reply in
            self?.picks.append(reply)
            return { [weak self] in self?.cancelledPickers += 1; reply(nil) }
        }
        controller.onSnapshot = { [weak self] _, reply in self?.reads.append(reply) }
        controller.isContextCurrent = { [weak self] in self?.context == true }
        controller.present(relativeTo: nil)
    }
    func load(_ snapshot: ClipboardFileRepairSnapshot? = nil) { reads.last?(.success(snapshot ?? initial)) }
    func showMenu(empty: Bool = false) {
        controller.openWithSelected(); load()
        discoveries.last?.1(.success(.init(applications: empty ? [] : [app], defaultApplication: empty ? nil : app)))
    }
    func choose(_ index: Int = 0, menu: NSMenu? = nil) throws {
        let item = try XCTUnwrap((menu ?? menus.last?.0)?.items[index])
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }
    func view<T: NSView>(_ type: T.Type, title: String? = nil, label: String? = nil) throws -> T {
        func find(_ view: NSView) -> T? {
            if let typed = view as? T, (title == nil || (typed as? NSButton)?.title == title), (label == nil || typed.accessibilityLabel() == label) { return typed }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(controller.window?.contentView.flatMap(find))
    }
    var status: String { (try? view(NSTextField.self, label: "文件操作状态"))?.stringValue ?? "" }
    static func fixture(readOnly: Bool) -> ClipboardFileRepairSnapshot {
        let files = (0..<2).map { index in
            let url = URL(fileURLWithPath: "/synthetic/folder\(index)/same.pdf")
            return ClipboardFileReference(partIndex: index, representationIndex: 0, rawURL: Data(url.absoluteString.utf8), url: url, status: .available, isOwned: false)
        }
        return .init(record: ClipboardRecord(text: "Synthetic Files", parts: files.map { .init(representations: [.init(typeIdentifier: "public.file-url", data: $0.rawURL)]) }),
                     files: files, syncConfiguration: .init(accountID: nil, generation: 0), sharingConfiguration: .init(accountID: nil, generation: 0), isReadOnly: readOnly)
    }
    func changed(status: ClipboardFileAvailability? = nil, url: URL? = nil, generation: Int64? = nil) -> ClipboardFileRepairSnapshot {
        var files = initial.files
        if status != nil || url != nil {
            let old = files[0]
            files[0] = .init(partIndex: old.partIndex, representationIndex: old.representationIndex,
                rawURL: url.map { Data($0.absoluteString.utf8) } ?? old.rawURL, url: url ?? old.url, status: status ?? old.status, isOwned: old.isOwned)
        }
        return .init(record: initial.record, files: files, syncConfiguration: .init(accountID: nil, generation: generation ?? 0),
                     sharingConfiguration: initial.sharingConfiguration, isReadOnly: initial.isReadOnly)
    }
}

@MainActor final class FileOpenWithTests: XCTestCase {
    func testExplicitChoiceRefreshesTwiceThenLaunchesExactFileAndApplicationIncludingReadOnly() throws {
        for readOnly in [false, true] {
            let h = OpenWithHarness(readOnly: readOnly); defer { h.controller.dismiss() }
            h.load(); XCTAssertTrue(h.discoveries.isEmpty); XCTAssertTrue(h.launches.isEmpty)
            let table = try h.view(NSTableView.self); table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            h.showMenu(); XCTAssertEqual(h.reads.count, 2); XCTAssertEqual(h.discoveries[0].0, h.initial.files[1].url)
            XCTAssertTrue(h.menus[0].0.items[0].title.contains("默认"))
            try h.choose(); XCTAssertEqual(h.reads.count, 3); XCTAssertTrue(h.launches.isEmpty)
            h.load(); XCTAssertEqual(h.launches.count, 1)
            XCTAssertEqual(h.launches[0].0, h.initial.files[1].url); XCTAssertEqual(h.launches[0].1, h.app)
            h.launches[0].2(.success(())); XCTAssertTrue(h.controller.window?.isVisible == true)
        }
    }
    func testCancelMenuAndOtherPickerProduceNoLaunchAndRestoreActions() throws {
        let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load(); h.showMenu()
        h.menus[0].1(); XCTAssertTrue(h.launches.isEmpty)
        XCTAssertTrue(try h.view(NSButton.self, title: "打开方式…").isEnabled)
        h.showMenu(empty: true)
        XCTAssertFalse(h.menus.last!.0.items[0].isEnabled)
        try h.choose(2); XCTAssertEqual(h.picks.count, 1)
        h.menus.last?.1(); h.picks[0](nil)
        XCTAssertTrue(h.launches.isEmpty); XCTAssertTrue(try h.view(NSButton.self, title: "打开方式…").isEnabled)
    }
    func testOtherApplicationRequiresValidBundleAndFreshStateBeforeOpening() throws {
        let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load(); h.showMenu(); try h.choose(2)
        h.picks[0](URL(fileURLWithPath: "/synthetic/not-app.txt"))
        XCTAssertTrue(h.launches.isEmpty); XCTAssertTrue(h.status.contains("不可用"))
        h.showMenu(); try h.choose(2)
        let other = URL(fileURLWithPath: "/Applications/Other.app")
        h.picks[1](other); XCTAssertTrue(h.launches.isEmpty)
        h.load(); XCTAssertEqual(h.launches.count, 1); XCTAssertEqual(h.launches[0].1, other)
    }
    func testMissingOrReplacedFileAndAccountGenerationChangePreventLaunch() throws {
        for variant in 0..<3 {
            let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load(); h.showMenu(); try h.choose()
            let updated = variant == 0 ? h.changed(status: .missing) : variant == 1 ? h.changed(url: URL(fileURLWithPath: "/synthetic/replaced.pdf")) : h.changed(generation: 2)
            h.load(updated); XCTAssertTrue(h.launches.isEmpty); XCTAssertTrue(h.status.contains("未打开"))
        }
    }
    func testMissingFileAtFirstRefreshDoesNotDiscoverAndExplainsFailure() {
        let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load()
        h.controller.openWithSelected(); h.load(h.changed(status: .missing))
        XCTAssertTrue(h.discoveries.isEmpty); XCTAssertTrue(h.launches.isEmpty)
        XCTAssertTrue(h.status.contains("未查询打开方式"))
    }
    func testDiscoveryFailureCanRetryAndOldMenuCannotChooseForNewIntent() throws {
        let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load()
        h.controller.openWithSelected(); h.load()
        h.discoveries[0].1(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Discovery unavailable"])))
        XCTAssertEqual(h.status, "Discovery unavailable")
        XCTAssertTrue(try h.view(NSButton.self, title: "打开方式…").isEnabled)
        h.showMenu(); let old = h.menus[0].0; h.menus[0].1()
        h.showMenu(); let before = h.reads.count
        try h.choose(menu: old)
        XCTAssertEqual(h.reads.count, before); XCTAssertTrue(h.launches.isEmpty)
        try h.choose(); h.load(); XCTAssertEqual(h.launches.count, 1)
    }
    func testChangedRecordRevisionAndFailedRefreshNeverLaunch() throws {
        for changedRevision in [false, true] {
            let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load(); h.showMenu(); try h.choose()
            if changedRevision {
                var record = h.initial.record; record.revision += 1
                h.load(.init(record: record, files: h.initial.files, syncConfiguration: h.initial.syncConfiguration,
                             sharingConfiguration: h.initial.sharingConfiguration, isReadOnly: false))
            } else { h.reads.last?(.failure(NSError(domain: "fixture", code: 1))) }
            XCTAssertTrue(h.launches.isEmpty); XCTAssertFalse(h.controller.snapshotIsCurrent)
        }
    }
    func testLateDiscoveryMenuItemPickerAndSnapshotCannotLaunchAfterDismiss() throws {
        for phase in 0..<4 {
            let h = OpenWithHarness(); h.load()
            if phase == 0 { h.controller.openWithSelected(); h.load() }
            else { h.showMenu(); if phase == 2 { try h.choose(2) }; if phase == 3 { try h.choose() } }
            h.controller.dismiss()
            switch phase {
            case 0: h.discoveries[0].1(.success(.init(applications: [h.app], defaultApplication: h.app)))
            case 1: try h.choose()
            case 2: h.picks[0](h.app); XCTAssertEqual(h.cancelledPickers, 1)
            default: h.load()
            }
            XCTAssertTrue(h.launches.isEmpty)
            if phase == 0 { XCTAssertTrue(h.menus.isEmpty) }
        }
    }
    func testRowChangeAndParentContextRetireOldMenuAndPicker() throws {
        for picker in [false, true] {
            let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load(); h.showMenu()
            let old = h.menus[0].0
            if picker { try h.choose(2) }
            try h.view(NSTableView.self).selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            if picker { h.picks[0](h.app); XCTAssertEqual(h.cancelledPickers, 1) }
            else { try h.choose(menu: old) }
            XCTAssertTrue(h.launches.isEmpty)
            h.showMenu(); h.context = false; try h.choose(); XCTAssertTrue(h.launches.isEmpty)
        }
    }
    func testOpenFailureKeepsWindowAndOffersRetryAndLateCompletionIsIgnored() throws {
        let h = OpenWithHarness(); h.load(); h.showMenu(); try h.choose(); h.load()
        let error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic launch failure"])
        h.launches[0].2(.failure(error))
        XCTAssertEqual(h.status, "Synthetic launch failure"); XCTAssertTrue(h.controller.window?.isVisible == true)
        XCTAssertTrue(try h.view(NSButton.self, title: "打开方式…").isEnabled)
        h.showMenu(); try h.choose(); h.load(); XCTAssertEqual(h.launches.count, 2)
        h.controller.dismiss(); let message = h.status
        h.launches[1].2(.success(())); XCTAssertEqual(h.status, message)
    }
    func testMinimumWindowKeepsOpenWithAndRepairAccessibleAndPickerIsOwned() throws {
        let h = OpenWithHarness(); defer { h.controller.dismiss() }; h.load()
        let window = try XCTUnwrap(h.controller.window)
        window.setContentSize(NSSize(width: 620, height: 450)); window.contentView?.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(window.contentView)
        for title in ["预览所选文件", "打开所选文件", "打开方式…", "重新定位…", "刷新状态", "返回列表"] {
            let button = try h.view(NSButton.self, title: title)
            XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)), title)
        }
        let chooser = UnshownTestPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.addChildWindow(chooser, ordered: .above)
        XCTAssertTrue(h.controller.ownsWindow(chooser)); window.removeChildWindow(chooser)
    }
}
