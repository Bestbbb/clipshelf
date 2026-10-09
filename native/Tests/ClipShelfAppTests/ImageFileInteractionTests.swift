import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

@MainActor private final class ImageInteractionHarness {
    let panel = ClipboardPanelController()
    let records: [ClipboardRecord]
    init(_ records: [ClipboardRecord]) {
        self.records = records
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
        panel.show(records: records)
        key(36, "\r") // Leave the search editor; no payload output on the first Return.
        key(0, "a", flags: .command)
    }
    @discardableResult func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) -> Bool {
        panel.handleKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: panel.window!.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }
    func view<T: NSView>(_ type: T.Type) throws -> T {
        func find(_ candidate: NSView) -> T? {
            if let result = candidate as? T { return result }
            return candidate.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(panel.window?.contentView.flatMap(find))
    }
    func card(_ index: Int = 0) throws -> ClipboardCardView {
        let collection = try view(NSCollectionView.self)
        let item = panel.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: index, section: 0))
        return try XCTUnwrap(item.view.subviews.compactMap { $0 as? ClipboardCardView }.first)
    }
    func menu(_ title: String) throws -> NSMenuItem { try XCTUnwrap(card().menu?.items.first { $0.title == title }) }
    func invoke(_ item: NSMenuItem) throws { panel.perform(try XCTUnwrap(item.action), with: item) }
    func close() { panel.dismiss() }
}

final class ImageFileInteractionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-interaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    @MainActor private func image(_ width: Int) throws -> ClipboardPart {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return .init(representations: [.init(typeIdentifier: "public.png", data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))])
    }
    @MainActor private func records() throws -> [ClipboardRecord] {
        [ClipboardRecord(text: "first image", copiedAt: Date(timeIntervalSince1970: 3), parts: [try image(4)], revision: 7),
         ClipboardRecord(text: "second image", copiedAt: Date(timeIntervalSince1970: 2), parts: [try image(5)], revision: 9)]
    }
    private func refs(_ records: [ClipboardRecord]) -> [ClipboardSelectionReference] { records.map { .init(id: $0.id, revision: $0.revision) } }
    @MainActor private func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], x: CGFloat = 40) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 60), modifierFlags: flags, timestamp: 1,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    @MainActor private func board() -> NSPasteboard { NSPasteboard(name: .init("ClipShelf.image-interaction.\(UUID().uuidString)")) }
    private func file(_ url: URL) -> ClipboardPart { .init(representations: [.init(typeIdentifier: "public.file-url", data: Data(url.absoluteString.utf8))]) }
    private func existing(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name); try Data(name.utf8).write(to: url); return url
    }

    @MainActor func testBothImageFileMenusResolveCompleteFrozenSelectionUsingStrictOutputReader() throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        var requests: [[ClipboardSelectionReference]] = [], replies: [(Result<[ClipboardRecord], Error>) -> Void] = []
        var output: [([UUID], Bool)] = [], genericReads = 0
        h.panel.resolveSelection = { _, _ in genericReads += 1 }
        h.panel.resolveOutputSelection = { selected, completion in requests.append(selected); replies.append(completion) }
        h.panel.onImageFileOutput = { output.append(($0.map(\.id), $1)) }
        for (title, directlyPaste) in [("复制为图片文件", false), ("作为图片文件粘贴", true)] {
            let item = try h.menu(title)
            XCTAssertTrue(item.target === h.panel)
            try h.invoke(item)
            XCTAssertEqual(requests.last, refs(original))
            try XCTUnwrap(replies.last)(.success(original))
            XCTAssertEqual(output.last?.0, original.map(\.id)); XCTAssertEqual(output.last?.1, directlyPaste)
        }
        XCTAssertEqual(genericReads, 0); XCTAssertEqual(output.count, 2)
    }

    @MainActor func testStrictReaderFailureAndPartialOrWrongRevisionRepliesNeverOutputSubset() throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        var reply: ((Result<[ClipboardRecord], Error>) -> Void)?, outputs = 0
        h.panel.resolveOutputSelection = { _, completion in reply = completion }
        h.panel.onImageFileOutput = { _, _ in outputs += 1 }
        let item = try h.menu("复制为图片文件")
        try h.invoke(item); try XCTUnwrap(reply)(.failure(ClipboardFileRepairError.unavailableOutput))
        try h.invoke(item); try XCTUnwrap(reply)(.success([original[0]]))
        var stale = original; stale[1].revision += 1
        try h.invoke(item); try XCTUnwrap(reply)(.success(stale))
        XCTAssertEqual(outputs, 0)
        try h.invoke(item); try XCTUnwrap(reply)(.success(original))
        XCTAssertEqual(outputs, 1, "An output error must leave repair/retry selection usable")
    }

    @MainActor func testNewMenuOutputRetiresOldResolverReplyAndOldConversionContext() throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        var replies: [(Result<[ClipboardRecord], Error>) -> Void] = [], calls: [Bool] = [], contexts: [() -> Bool] = []
        h.panel.resolveOutputSelection = { _, reply in replies.append(reply) }
        h.panel.onImageFileOutput = { _, paste in calls.append(paste); contexts.append(h.panel.captureOutputContext()) }
        try h.invoke(h.menu("复制为图片文件"))
        try h.invoke(h.menu("作为图片文件粘贴"))
        XCTAssertEqual(replies.count, 2)
        replies[0](.success(original)); XCTAssertTrue(calls.isEmpty)
        replies[1](.success(original)); XCTAssertEqual(calls, [true]); XCTAssertTrue(try XCTUnwrap(contexts.last)())
        let oldContext = try XCTUnwrap(contexts.last)
        try h.invoke(h.menu("复制为图片文件"))
        XCTAssertFalse(oldContext())
        replies[2](.success(original)); XCTAssertEqual(calls, [true, false])
    }

    @MainActor func testOutputContextAndPendingResolverExpireOnNewSelectionQueryScopeAndClose() throws {
        for transition in 0..<4 {
            let original = try records(), h = ImageInteractionHarness(original)
            defer { h.close() }
            var reply: ((Result<[ClipboardRecord], Error>) -> Void)?, outputs = 0
            h.panel.resolveOutputSelection = { _, completion in reply = completion }
            h.panel.onImageFileOutput = { _, _ in outputs += 1 }
            try h.invoke(h.menu("复制为图片文件"))
            let old = try XCTUnwrap(reply), isCurrent = h.panel.captureOutputContext()
            XCTAssertTrue(isCurrent())
            switch transition {
            case 0: h.key(124)
            case 1:
                let search = try h.view(NSSearchField.self)
                search.stringValue = "new query"; h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            case 2:
                h.panel.setPinboards([Pinboard(name: "different scope")])
                func find(_ v: NSView) -> NSPopUpButton? {
                    if let popup = v as? NSPopUpButton, popup.accessibilityLabel() == "分组" { return popup }
                    return v.subviews.lazy.compactMap(find).first
                }
                let popup = try XCTUnwrap(h.panel.window?.contentView.flatMap(find))
                popup.selectItem(at: 1); h.panel.perform(NSSelectorFromString("boardChanged"))
            default: h.panel.dismiss(); h.panel.show(records: original)
            }
            XCTAssertFalse(isCurrent(), "transition \(transition)")
            old(.success(original)); XCTAssertEqual(outputs, 0, "transition \(transition)")
        }
    }

    @MainActor func testSearchFocusWithoutTypingPermanentlyRetiresPendingImageConversion() throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        var context: (() -> Bool)?
        h.panel.resolveOutputSelection = { _, reply in reply(.success(original)) }
        h.panel.onImageFileOutput = { _, _ in context = h.panel.captureOutputContext() }
        try h.invoke(h.menu("复制为图片文件"))
        let isCurrent = try XCTUnwrap(context)
        XCTAssertTrue(isCurrent())
        let search = try h.view(NSSearchField.self)
        let keyword = search.stringValue
        XCTAssertTrue(h.key(3, "f", flags: .command))
        XCTAssertEqual(search.stringValue, keyword, "Focusing search alone must retire conversion without a new query")
        XCTAssertFalse(isCurrent())
        XCTAssertTrue(h.key(36, "\r"))
        XCTAssertFalse(isCurrent(), "Returning to results must not revive the old conversion")
    }

    @MainActor func testShiftTabThenReturnNeverRevivesOldImageConversionContext() throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        var context: (() -> Bool)?
        h.panel.resolveOutputSelection = { _, reply in reply(.success(original)) }
        h.panel.onImageFileOutput = { _, _ in context = h.panel.captureOutputContext() }
        try h.invoke(h.menu("复制为图片文件"))
        let old = try XCTUnwrap(context)
        XCTAssertTrue(old())
        XCTAssertTrue(h.key(48, "\t", flags: .shift))
        XCTAssertFalse(old())
        XCTAssertTrue(h.key(36, "\r"))
        XCTAssertTrue(h.panel.captureOutputContext()(), "A fresh context is usable after returning to results")
        XCTAssertFalse(old(), "The original action stays retired after the boolean focus guard becomes true again")
    }

    @MainActor func testOpeningAndCancellingAllFiltersNeverRevivesOldImageConversionContext() throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        h.panel.presentFilterPopover = { _, _ in } // Construct the real controller, never show desktop UI.
        var context: (() -> Bool)?
        h.panel.resolveOutputSelection = { _, reply in reply(.success(original)) }
        h.panel.onImageFileOutput = { _, _ in context = h.panel.captureOutputContext() }
        try h.invoke(h.menu("复制为图片文件"))
        let old = try XCTUnwrap(context)
        XCTAssertTrue(old())
        h.panel.showAllFilters()
        let filters = try XCTUnwrap(h.panel.allFiltersController)
        XCTAssertFalse(old())
        filters.onCancel?()
        XCTAssertNil(h.panel.allFiltersController)
        XCTAssertTrue(h.key(36, "\r"))
        XCTAssertTrue(h.panel.captureOutputContext()())
        XCTAssertFalse(old(), "Cancelling the unchanged filter draft must not revive unpublished image output")
        XCTAssertNil(h.panel.window?.attachedSheet)
    }

    @MainActor func testRenamePreparesReferenceAndRetiresConversionBeforeAnyReplyOrAlert() throws {
        for deferredOutputRead in [false, true] {
            let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
            var preparations: [(ClipboardSelectionReference, (Result<ClipboardEditSnapshot, Error>) -> Void)] = []
            var unresolvedOutput: ((Result<[ClipboardRecord], Error>) -> Void)?
            var completeConversion: (() -> Void)?, conversionStarts = 0, outputs = 0, genericReads = 0
            h.panel.presentDetailPanel = { _, _ in } // Keep the real editor unshown.
            h.panel.resolveSelection = { _, _ in genericReads += 1 }
            h.panel.onPrepareEdit = { reference, reply in preparations.append((reference, reply)) }
            h.panel.resolveOutputSelection = { _, reply in unresolvedOutput = reply }
            h.panel.onImageFileOutput = { _, _ in
                conversionStarts += 1
                let isCurrent = h.panel.captureOutputContext()
                completeConversion = { if isCurrent() { outputs += 1 } }
            }
            try h.invoke(h.menu("复制为图片文件"))
            let outputReply = try XCTUnwrap(unresolvedOutput)
            if !deferredOutputRead { outputReply(.success(original)) }
            let isCurrent = h.panel.captureOutputContext()
            XCTAssertTrue(isCurrent())
            XCTAssertTrue(h.key(15, "r", flags: .command))
            XCTAssertEqual(genericReads, 0, "Rename must prepare its reference without hydrating through the generic reader")
            XCTAssertEqual(preparations.count, 1)
            let preparation = try XCTUnwrap(preparations.first)
            XCTAssertTrue(refs(original).contains(preparation.0))
            XCTAssertFalse(isCurrent(), "Starting rename retires conversion before the deferred preparation completes")
            XCTAssertNil(h.panel.window?.attachedSheet, "Pending preparation must not show a modal alert")

            if deferredOutputRead { outputReply(.success(original)) }
            else { try XCTUnwrap(completeConversion)() }
            XCTAssertEqual(conversionStarts, deferredOutputRead ? 0 : 1, "A late output read cannot start conversion behind the editor")
            XCTAssertEqual(outputs, 0, "An already-started conversion cannot publish its late result")

            let preparedRecord = try XCTUnwrap(original.first { $0.id == preparation.0.id })
            preparation.1(.success(.init(record: preparedRecord)))
            XCTAssertFalse(isCurrent(), "A successful rename preparation must not revive the old output action")
            completeConversion?()
            XCTAssertEqual(outputs, 0)
            XCTAssertNil(h.panel.window?.attachedSheet)
        }
    }

    @MainActor func testImageMenuExplicitlyFocusesResultsBeforeCapturingConversionContext() throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        XCTAssertTrue(h.key(3, "f", flags: .command))
        XCTAssertFalse(h.panel.captureOutputContext()())
        var requests: [[ClipboardSelectionReference]] = [], context: (() -> Bool)?
        h.panel.resolveOutputSelection = { references, reply in requests.append(references); reply(.success(original)) }
        h.panel.onImageFileOutput = { _, _ in context = h.panel.captureOutputContext() }
        try h.invoke(h.menu("复制为图片文件"))
        XCTAssertEqual(requests, [refs(original)])
        XCTAssertTrue(try XCTUnwrap(context)())
    }

    @MainActor func testImageFileMenuUsesIndependentImagePartsInsteadOfAggregateKindOrFileThumbnail() throws {
        let external = try existing("file-with-image.txt")
        let standalone = try image(7)
        var thumbnail = file(external); thumbnail.representations += standalone.representations
        let mixed = ClipboardRecord(text: "file and independent image", parts: [file(external), standalone])
        let onlyThumbnail = ClipboardRecord(text: "file thumbnail", parts: [thumbnail])
        XCTAssertEqual(mixed.kind, .file); XCTAssertEqual(onlyThumbnail.kind, .file)
        XCTAssertTrue(ClipboardCardContent(mixed).hasImageFileParts)
        XCTAssertFalse(ClipboardCardContent(onlyThumbnail).hasImageFileParts)
        for (record, expected) in [(mixed, true), (onlyThumbnail, false)] {
            let h = ImageInteractionHarness([record]); defer { h.close() }
            for title in ["复制为图片文件", "作为图片文件粘贴"] {
                let menu = try h.menu(title)
                XCTAssertEqual(h.panel.validateMenuItem(menu), expected)
            }
        }
    }

    @MainActor func testImageFileMenusOnSelectedTextAndFileCardsFreezeWholeMixedBatch() throws {
        let imageRecord = ClipboardRecord(text: "image", copiedAt: Date(timeIntervalSince1970: 3), parts: [try image(8)])
        let fileRecord = ClipboardRecord(text: "file", copiedAt: Date(timeIntervalSince1970: 2), parts: [file(try existing("mixed.txt"))])
        let textRecord = ClipboardRecord(text: "text", copiedAt: Date(timeIntervalSince1970: 1))
        let original = [imageRecord, fileRecord, textRecord], h = ImageInteractionHarness(original)
        defer { h.close() }
        var requested: [[ClipboardSelectionReference]] = [], outputs: [[UUID]] = []
        h.panel.resolveOutputSelection = { references, reply in requested.append(references); reply(.success(original)) }
        h.panel.onImageFileOutput = { records, _ in outputs.append(records.map(\.id)) }
        for index in [1, 2] {
            let card = try h.card(index)
            XCTAssertFalse(card.record.hasImageFileParts)
            for title in ["复制为图片文件", "作为图片文件粘贴"] {
                let item = try XCTUnwrap(card.menu?.items.first { $0.title == title })
                XCTAssertTrue(h.panel.validateMenuItem(item))
                try h.invoke(item)
                XCTAssertEqual(requested.last, refs(original))
                XCTAssertEqual(outputs.last, original.map(\.id))
            }
        }
        XCTAssertEqual(outputs.count, 4)
        let single = ImageInteractionHarness([textRecord]); defer { single.close() }
        XCTAssertFalse(single.panel.validateMenuItem(try single.menu("复制为图片文件")))
        XCTAssertFalse(single.panel.validateMenuItem(try single.menu("作为图片文件粘贴")))
    }

    @MainActor func testPreparedWritersKeepPartOrderAndImagePromisesDoNotExposeHistoryMarkers() throws {
        let external = try existing("existing.txt")
        let text = ClipboardPart(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("middle text".utf8))])
        let original = [ClipboardRecord(text: "multipart", parts: [try image(3), text, file(external)], revision: 4),
                        ClipboardRecord(text: "last", parts: [try image(6)], revision: 8)]
        let prepared = try ImageFileOutput.prepare(original)
        XCTAssertEqual(prepared.imageCount, 2)
        let writers = try prepared.draggingWriters()
        XCTAssertEqual(writers.count, 4)
        XCTAssertEqual((writers[0] as? NSFilePromiseProvider)?.fileType, "public.png")
        XCTAssertEqual((writers[1] as? NSPasteboardItem)?.string(forType: .string), "middle text")
        XCTAssertEqual((writers[2] as? NSPasteboardItem)?.string(forType: .fileURL), external.absoluteString)
        XCTAssertEqual((writers[3] as? NSFilePromiseProvider)?.fileType, "public.png")
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(writers.allSatisfy { !$0.writableTypes(for: pasteboard).contains(ClipboardCardView.recordIDType) })
        let card = ClipboardCardView(record: .init(original[0]), position: 0)
        card.mouseDown(with: mouse(.leftMouseDown, flags: .option))
        let gesture = try XCTUnwrap(card.activeGestureID), origin = UUID(), scope = UUID(), selection = UUID()
        card.preparePayloadDrag(originID: origin, scopeID: scope, selectionID: selection)
        XCTAssertTrue(card.providePreparedImageFiles(prepared, records: original, gestureID: gesture))
        XCTAssertEqual(card.draggedReferences, refs(original)); XCTAssertEqual(card.draggedRecordIDs, original.map(\.id))
        XCTAssertEqual(card.draggedRecordRevisions, [original[0].id: 4, original[1].id: 8])
        XCTAssertEqual(card.dragOriginID, origin); XCTAssertEqual(card.dragScopeID, scope); XCTAssertEqual(card.dragSelectionID, selection)
        XCTAssertEqual(card.dragOperationMask(for: .outsideApplication), .copy)
        card.cancelPendingDrag()
    }

    @MainActor func testOldPreparedImageGestureCannotPopulateOrRejectReplacementGesture() throws {
        let original = try records(), prepared = try ImageFileOutput.prepare(original)
        let card = ClipboardCardView(record: .init(original[0]), position: 0)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 250), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        XCTAssertFalse(window.isVisible)
        card.mouseDown(with: mouse(.leftMouseDown, flags: .option)); card.preparePayloadDrag(originID: UUID())
        let first = try XCTUnwrap(card.activeGestureID)
        card.mouseUp(with: mouse(.leftMouseUp))
        card.mouseDown(with: mouse(.leftMouseDown, flags: .option)); card.preparePayloadDrag(originID: UUID())
        let second = try XCTUnwrap(card.activeGestureID)
        var errors = 0; card.onDragError = { _ in errors += 1 }
        XCTAssertFalse(card.providePreparedImageFiles(prepared, records: original, gestureID: first))
        card.rejectPreparedPayload(ImageFileOutputError.invalidImage, gestureID: first)
        XCTAssertEqual(card.activeGestureID, second); XCTAssertTrue(card.draggedRecordIDs.isEmpty); XCTAssertEqual(errors, 0)
        XCTAssertTrue(card.providePreparedImageFiles(prepared, records: original, gestureID: second))
        card.mouseDragged(with: mouse(.leftMouseDragged, x: 90))
        XCTAssertTrue(card.hasPreparedDragGesture)
        card.rejectPreparedPayload(ImageFileOutputError.invalidImage, gestureID: first)
        XCTAssertTrue(card.hasPreparedDragGesture); XCTAssertEqual(card.draggedReferences, refs(original))
        card.cancelPendingDrag(); XCTAssertNil(card.activeGestureID)
        XCTAssertFalse(card.providePreparedImageFiles(prepared, records: original, gestureID: second))
        card.rejectPreparedPayload(ImageFileOutputError.invalidImage, gestureID: second)
        XCTAssertEqual(errors, 0); XCTAssertFalse(card.hasPreparedDragGesture)
    }

    @MainActor func testCurrentImagePreparationFailureAndWindowDetachCancelOnlyCurrentGesture() throws {
        let original = try records(), prepared = try ImageFileOutput.prepare(original)
        let card = ClipboardCardView(record: .init(original[0]), position: 0)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 250), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        var errors = 0; card.onDragError = { _ in errors += 1 }
        card.mouseDown(with: mouse(.leftMouseDown)); card.preparePayloadDrag(originID: UUID())
        let gesture = try XCTUnwrap(card.activeGestureID)
        card.rejectPreparedPayload(ImageFileOutputError.invalidImage, gestureID: gesture)
        XCTAssertEqual(errors, 1); XCTAssertNil(card.activeGestureID); XCTAssertTrue(card.draggedReferences.isEmpty)
        XCTAssertFalse(card.providePreparedImageFiles(prepared, records: original, gestureID: gesture))
        card.mouseDown(with: mouse(.leftMouseDown)); card.preparePayloadDrag(originID: UUID())
        let next = try XCTUnwrap(card.activeGestureID)
        card.removeFromSuperview()
        XCTAssertNil(card.activeGestureID); XCTAssertNil(card.window)
        XCTAssertFalse(card.providePreparedImageFiles(prepared, records: original, gestureID: next))
        XCTAssertEqual(errors, 1)
    }

    @MainActor func testOptionDragUsesStrictFrozenSelectionWhileNormalImageDragKeepsRawPayload() async throws {
        let original = try records(), h = ImageInteractionHarness(original); defer { h.close() }
        var requested: [[ClipboardSelectionReference]] = [], generic = 0
        h.panel.resolveSelection = { _, _ in generic += 1 }
        h.panel.resolveOutputSelection = { selected, reply in requested.append(selected); reply(.success(original)) }
        let ordinary = try h.card()
        ordinary.mouseDown(with: mouse(.leftMouseDown))
        XCTAssertEqual(ordinary.draggedReferences, refs(original))
        ordinary.cancelPendingDrag()
        let converted = try h.card()
        converted.mouseDown(with: mouse(.leftMouseDown, flags: .option))
        let gesture = try XCTUnwrap(converted.activeGestureID)
        let deadline = Date().addingTimeInterval(2)
        while converted.draggedReferences.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(converted.activeGestureID, gesture)
        XCTAssertEqual(converted.draggedReferences, refs(original))
        XCTAssertEqual(requested, [refs(original), refs(original)]); XCTAssertEqual(generic, 0)
        converted.cancelPendingDrag()
    }

    @MainActor func testManualOrderingCannotBeChangedIntoImageFileOutputAndNormalDragKeepsPNG() throws {
        let original = try records(), prepared = try ImageFileOutput.prepare(original)
        let normal = try ClipboardCardView.payloadDragItems(for: original)
        XCTAssertEqual(normal.count, original.count)
        for (item, record) in zip(normal, original) {
            XCTAssertEqual(item.data(forType: .png), record.parts[0].representations[0].data)
            XCTAssertNil(item.string(forType: .fileURL)); XCTAssertFalse(item.types.contains(ClipboardCardView.recordIDType))
        }
        let card = ClipboardCardView(record: .init(original[0]), position: 0)
        card.mouseDown(with: mouse(.leftMouseDown))
        let gesture = try XCTUnwrap(card.activeGestureID)
        card.prepareOrderingDrag(references: refs(original), originID: UUID())
        XCTAssertFalse(card.providePreparedImageFiles(prepared, records: original, gestureID: gesture))
        XCTAssertEqual(card.draggedReferences, refs(original))
        XCTAssertEqual(card.dragOperationMask(for: .withinApplication), .move)
        XCTAssertTrue(card.dragOperationMask(for: .outsideApplication).isEmpty)
        XCTAssertEqual(ClipboardCardView.orderingDragItems(for: card.draggedReferences).first?.types, [ClipboardCardView.recordIDType])
        card.cancelPendingDrag()
    }

    @MainActor func testOnCopiedRunsAfterSuccessfulPrivatePasteboardWriteBeforeDismissWithoutDispatch() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString("before", forType: .string))
        let first = try existing("first.png"), second = try existing("second.png")
        let original = [ClipboardRecord(text: "first", parts: [file(first)]), ClipboardRecord(text: "second", parts: [file(second)])]
        let coordinator = PasteCoordinator(pasteboard: pasteboard)
        var events: [String] = [], messages: [String] = []
        coordinator.onClipboardWrite = { events.append("write") }
        coordinator.onResult = { messages.append($0) }
        coordinator.paste(original, plainText: false, target: nil, dismiss: { events.append("dismiss") }, onCopied: {
            XCTAssertEqual(pasteboard.pasteboardItems?.map { $0.string(forType: .fileURL) }, [first.absoluteString, second.absoluteString])
            events.append("copied")
        }, onDispatched: { events.append("dispatched") })
        XCTAssertEqual(events, ["write", "copied", "dismiss"])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(try XCTUnwrap(messages.first).contains("已复制"))
    }

    @MainActor func testFailedImageFilePastePreservesPasteboardAndDoesNotCopyDismissOrDispatch() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        let before = NSPasteboardItem(); before.setString("before failure", forType: .string)
        before.setData(Data([0, 255]), forType: .init("org.example.original"))
        XCTAssertTrue(pasteboard.writeObjects([before]))
        let count = pasteboard.changeCount
        let original = [ClipboardRecord(text: "available", parts: [file(try existing("available.png"))]),
                        ClipboardRecord(text: "missing", parts: [file(directory.appendingPathComponent("missing.png"))])]
        let coordinator = PasteCoordinator(pasteboard: pasteboard)
        var events: [String] = [], errors = 0
        coordinator.onClipboardWrite = { events.append("write") }; coordinator.onResult = { _ in errors += 1 }
        coordinator.paste(original, plainText: false, target: nil, dismiss: { events.append("dismiss") },
                          onCopied: { events.append("copied") }, onDispatched: { events.append("dispatched") })
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(errors, 1)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "before failure")
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: .init("org.example.original")), Data([0, 255]))
    }
}
