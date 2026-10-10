import ClipShelfLocalization
import AppKit
import ClipShelfCore

/// Core owns reachability, filesystem recovery, and cross-connection exclusion.
/// This controller only coordinates the visible confirmation and application lifetime.
@MainActor
final class StorageSettingsController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    struct Actions {
        var scan: @MainActor () async throws -> OwnedStorageUsage
        var prepare: @MainActor () async throws -> OwnedStorageCleanupPlan
        var commit: @MainActor (OwnedStorageCleanupPlan) async throws -> OwnedStorageCleanupResult
        var recover: @MainActor () async throws -> OwnedStorageCleanupResult
        var readExternalUses: (@MainActor () async throws -> [OwnedAssetPublication])? = nil
        var releaseExternalUses: (@MainActor (Set<UUID>) async throws -> Void)? = nil
        var scanLibrary: (@MainActor (HistoryReadCancellation) async throws -> LibraryStorageSnapshot)? = nil
        var readContentQuota: (@MainActor () async throws -> LibraryContentQuotaStatus)? = nil
        var setContentQuota: (@MainActor (Int64?, Int64) async throws -> LibraryContentQuotaStatus)? = nil
    }
    enum Phase { case idle, scanning, preparing, confirming, committing, recovering, savingLimit }
    private let actions: Actions
    private let preferences: UserDefaults
    private let status = NSTextField(wrappingLabelWithString: L10n.text("刷新后查看当前资料库托管文件的占用。"))
    private let detail = NSTextField(wrappingLabelWithString: L10n.text("尚未读取，不能据此判断为零。"))
    private let libraryDetail = NSTextField(wrappingLabelWithString: "")
    private var libraryCancellation: HistoryReadCancellation?
    private(set) var libraryUsage: LibraryStorageSnapshot?
    private(set) var contentQuota: LibraryContentQuotaStatus?
    private let quotaDetail = NSTextField(wrappingLabelWithString: L10n.text("尚未读取，不能据此判断为零。"))
    private let quotaNotice = NSTextField(wrappingLabelWithString: "")
    private let quotaMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quotaMiB = NSTextField(string: "")
    private let quotaSave = NSButton(title: L10n.text("保存上限"), target: nil, action: nil)
    private var quotaDraftGeneration: UInt64 = 0
    private var quotaDraftDirty = false
    private var presentationGeneration: UInt64 = 0
    private let refreshButton = NSButton(title: L10n.text("刷新占用"), target: nil, action: nil)
    private let cleanupButton = NSButton(title: L10n.text("清理可回收文件…"), target: nil, action: nil)
    private let recoverButton = NSButton(title: L10n.text("继续中断的回收"), target: nil, action: nil)
    private let externalUsesButton = NSButton(title: L10n.text("管理外部使用保护…"), target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: L10n.text("自动回收已不再使用的托管文件"), target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var cancelConfirmation: (() -> Void)?
    private var automaticQueued = false
    private var recoveryQueued = false
    private(set) var phase: Phase = .idle
    private(set) var usage: OwnedStorageUsage?
    var isBusy: Bool { phase != .idle }
    var isCommitting: Bool { phase == .committing || phase == .recovering || phase == .savingLimit }
    var isExternalMutationBusy: (() -> Bool)?
    var allowsLibraryScan: (() -> Bool)?
    /// Failed captures containing file references may block reclamation, but must not
    /// prevent raising or disabling the content limit needed to save those captures.
    var allowsLimitChange: (() -> Bool)?
    var onBusyChanged: ((Bool) -> Void)?
    var onMessage: ((String) -> Void)?
    var confirmation: ((OwnedStorageCleanupPlan, @escaping (Bool) -> Void) -> (() -> Void))?

    init(actions: Actions, preferences: UserDefaults = .standard) {
        self.actions = actions; self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("ClipShelf · 存储管理"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 500)
        super.init(window: window)
        window.delegate = self
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byTruncatingTail
        let description = NSTextField(wrappingLabelWithString: L10n.text("统计托管原件与打开副本。仍在历史、撤销、Stack、编辑、同步或外部使用中的文件会保留。修改过的打开副本与无法验证的文件不会自动删除。"))
        description.textColor = .secondaryLabelColor
        let scope = NSTextField(wrappingLabelWithString: L10n.text("以下数值不含数据库、普通表示附件、OCR、导出缓存和独立备份；外部 Finder 原文件也不在此范围。文件系统分配字节不等于卷上可释放的空间。"))
        scope.textColor = .secondaryLabelColor
        automatic.state = preferences.bool(forKey: "automaticallyReclaimOwnedFiles") ? .on : .off
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        cleanupButton.target = self; cleanupButton.action = #selector(cleanup)
        recoverButton.target = self; recoverButton.action = #selector(recover)
        externalUsesButton.target = self; externalUsesButton.action = #selector(manageExternalUses)
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        let controls = NSStackView(views: [refreshButton, cleanupButton, recoverButton]); controls.spacing = 12
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let libraryScope = NSTextField(wrappingLabelWithString: L10n.text("共享缓存单独列出，外部 Finder 原文件不计入。统计不等于可回收空间；总容量默认不设上限。"))
        libraryScope.textColor = .secondaryLabelColor
        libraryDetail.isHidden = actions.scanLibrary == nil
        libraryScope.isHidden = actions.scanLibrary == nil
        if actions.scanLibrary != nil {
            libraryDetail.stringValue = L10n.text("尚未读取，不能据此判断为零。")
            status.stringValue = L10n.text("刷新后查看资料库、缓存与备份的占用。")
            invalidateManagedUsage()
        }
        let quotaHeading = NSTextField(labelWithString: L10n.text("保存数据上限"))
        quotaHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        let quotaScope = NSTextField(wrappingLabelWithString: L10n.text("按保存的数据大小计量，包含记录内容、去重后的当前附件、已登记的托管原件和本地同步数据。不含数据库日志与索引、打开副本、备份、缓存和暂存文件；这不是整个资料库的磁盘占用上限。"))
        quotaScope.textColor = .secondaryLabelColor
        let quotaEffect = NSTextField(wrappingLabelWithString: L10n.text("默认不限。调低上限不会删除已有内容；超出时停止进一步增长。清理或调高上限后，请在菜单中明确重试保存。"))
        quotaEffect.textColor = .secondaryLabelColor
        quotaMode.addItems(withTitles: [L10n.text("不限"), L10n.text("限制大小")])
        quotaMode.setAccessibilityIdentifier("storage.quota.mode")
        quotaMode.setAccessibilityLabel(L10n.text("保存数据上限"))
        quotaMode.target = self; quotaMode.action = #selector(changeQuotaDraft)
        quotaMiB.setAccessibilityIdentifier("storage.quota.mib")
        quotaMiB.setAccessibilityLabel(L10n.text("上限（MiB 正整数）"))
        quotaMiB.placeholderString = L10n.text("MiB 正整数")
        quotaMiB.delegate = self
        quotaSave.setAccessibilityIdentifier("storage.quota.save")
        quotaSave.target = self; quotaSave.action = #selector(saveContentQuota)
        quotaDetail.setAccessibilityIdentifier("storage.quota.usage")
        quotaNotice.setAccessibilityIdentifier("storage.quota.notice")
        let quotaInput = NSStackView(views: [quotaMiB, NSTextField(labelWithString: "MiB")]); quotaInput.spacing = 8
        let quotaBox = NSStackView(views: [quotaHeading, quotaScope, quotaDetail, quotaMode, quotaInput, quotaSave, quotaEffect, quotaNotice])
        quotaBox.orientation = .vertical; quotaBox.alignment = .leading; quotaBox.spacing = 10
        let hasQuota = actions.readContentQuota != nil && actions.setContentQuota != nil
        let sections: [NSView] = [libraryDetail, libraryScope, description, detail, scope]
        let content = NSStackView(views: hasQuota ? [quotaBox] + sections : sections)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = content
        let body = NSStackView(views: [status, scroll, automatic, externalUsesButton, controls])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 18
        body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = body
        defer { InterfaceLayout.apply(to: body) }
        NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -48),
            scroll.widthAnchor.constraint(equalTo: status.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -18),
            description.widthAnchor.constraint(equalTo: content.widthAnchor), detail.widthAnchor.constraint(equalTo: content.widthAnchor),
            scope.widthAnchor.constraint(equalTo: content.widthAnchor),
            libraryDetail.widthAnchor.constraint(equalTo: content.widthAnchor),
            libraryScope.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        if hasQuota {
            NSLayoutConstraint.activate([
                quotaBox.widthAnchor.constraint(equalTo: content.widthAnchor),
                quotaScope.widthAnchor.constraint(equalTo: quotaBox.widthAnchor),
                quotaDetail.widthAnchor.constraint(equalTo: quotaBox.widthAnchor),
                quotaEffect.widthAnchor.constraint(equalTo: quotaBox.widthAnchor),
                quotaNotice.widthAnchor.constraint(equalTo: quotaBox.widthAnchor),
                quotaMiB.widthAnchor.constraint(equalToConstant: 180),
            ])
        }
        renderControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !isBusy { refresh() }
    }
    func windowWillClose(_ notification: Notification) { _ = cancelPending() }
    func suspend() { _ = cancelPending(); window?.orderOut(nil) }

    /// Once Core starts a journaled commit/recovery, hiding the window does not cancel it.
    @discardableResult
    func cancelPending() -> Bool {
        automaticQueued = false; recoveryQueued = false
        presentationGeneration &+= 1
        guard !isCommitting else { return false }
        generation &+= 1; libraryCancellation?.cancel(); libraryCancellation = nil
        task?.cancel(); task = nil
        let dismiss = cancelConfirmation; cancelConfirmation = nil; dismiss?()
        if isBusy { status.stringValue = L10n.text("已取消，未开始回收文件。") }
        setPhase(.idle)
        return true
    }
    func requestAutomaticReclamation() {
        guard preferences.bool(forKey: "automaticallyReclaimOwnedFiles") else { return }
        automaticQueued = true; resumeDeferred()
    }
    func requestRecovery() { recoveryQueued = true; resumeDeferred() }
    func resumeDeferred() {
        guard !isBusy, isExternalMutationBusy?() != true else { return }
        if recoveryQueued { recoveryQueued = false; recover() }
        else if automaticQueued {
            automaticQueued = false
            if preferences.bool(forKey: "automaticallyReclaimOwnedFiles") { prepareCleanup(automatic: true) }
        }
    }

    @objc func refresh() {
        if actions.readContentQuota != nil {
            guard !isBusy else { return }
            guard allowsLibraryScan?() != false else {
                status.stringValue = L10n.text("其他修改正在进行，请稍后重试。"); return
            }
            refreshWithQuota(); return
        }
        if let scanLibrary = actions.scanLibrary {
            guard !isBusy else { return }
            guard allowsLibraryScan?() != false else {
                status.stringValue = L10n.text("其他修改正在进行，请稍后重试。"); return
            }
            refreshLibrary(scanLibrary); return
        }
        guard canBegin() else { return }
        let current = begin(.scanning, message: L10n.text("正在核对文件占用与保留依赖…"))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let report = try await self.actions.scan()
                guard self.accepts(current) else { return }
                self.display(report)
                self.status.stringValue = (report.measurementComplete ? L10n.text("占用已更新") : L10n.text("占用已部分更新，仍有待检查内容")) + " · \(L10n.date(Date(), includesDate: false))"
            } catch {
                guard self.accepts(current) else { return }
                self.usage = nil
                self.detail.stringValue = L10n.text("无法取得完整统计，未将未知占用显示为零。\n\(error.localizedDescription)")
                self.status.stringValue = L10n.text("读取未完成，原因见下方。")
            }
            self.finish(current)
        }
    }

    private func refreshLibrary(_ scan: @escaping @MainActor (HistoryReadCancellation) async throws -> LibraryStorageSnapshot) {
        invalidateManagedUsage()
        let current = begin(.scanning, message: L10n.text("正在统计资料库、缓存与备份…"))
        let cancellation = HistoryReadCancellation(); libraryCancellation = cancellation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await scan(cancellation)
                guard self.accepts(current) else { return }
                self.libraryUsage = snapshot
                self.libraryDetail.stringValue = LibraryStorageReader.describe(snapshot)
                self.status.stringValue = snapshot.report.isPartial
                    ? L10n.text("占用已部分更新，仍有待检查内容") : L10n.text("占用已更新")
            } catch {
                guard self.accepts(current) else { return }
                self.libraryUsage = nil
                self.libraryDetail.stringValue = L10n.text("无法取得完整统计，未将未知占用显示为零。\n\(error.localizedDescription)")
                self.status.stringValue = L10n.text("读取未完成，原因见下方。")
            }
            self.libraryCancellation = nil
            self.finish(current)
        }
    }

    private func refreshWithQuota() {
        let current = begin(.scanning, message: L10n.text("正在读取保存数据用量与上限…"))
        let draft = quotaDraftGeneration
        let cancellation = HistoryReadCancellation(); libraryCancellation = cancellation
        if actions.scanLibrary != nil { invalidateManagedUsage() }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let read = self.actions.readContentQuota {
                    let value = try await read()
                    guard self.accepts(current) else { return }
                    self.displayQuota(value, draftGeneration: draft)
                }
            } catch {
                guard self.accepts(current) else { return }
                self.contentQuota = nil
                self.quotaDetail.stringValue = L10n.text("无法读取保存数据用量与上限，未将未知用量显示为零。\n\(error.localizedDescription)")
            }
            guard self.accepts(current) else { return }
            // A content-policy read is independent of the physical scan and dependency audit.
            // Failed captures holding file references can still read and raise their limit.
            do {
                if let scan = self.actions.scanLibrary {
                    let snapshot = try await scan(cancellation)
                    guard self.accepts(current) else { return }
                    self.libraryUsage = snapshot
                    self.libraryDetail.stringValue = LibraryStorageReader.describe(snapshot)
                }
            } catch {
                guard self.accepts(current) else { return }
                self.libraryUsage = nil
                self.libraryDetail.stringValue = L10n.text("无法取得完整统计，未将未知占用显示为零。\n\(error.localizedDescription)")
            }
            guard self.accepts(current) else { return }
            self.libraryCancellation = nil
            self.status.stringValue = self.contentQuota == nil ? L10n.text("读取未完成，原因见下方。") : L10n.text("保存数据用量与上限已更新。")
            self.finish(current)
        }
    }

    private func displayQuota(_ value: LibraryContentQuotaStatus, draftGeneration: UInt64? = nil) {
        contentQuota = value
        let limit = value.limitBytes.map(Self.bytes) ?? L10n.text("不限")
        var lines = [L10n.text("保存数据：\(Self.bytes(value.usedBytes)) · 上限：\(limit)"),
            L10n.text("记录内容：\(Self.bytes(value.recordBytes)) · 当前附件：\(Self.bytes(value.representationBytes))"),
            L10n.text("托管原件：\(Self.bytes(value.ownedFileBytes)) · 同步数据：\(Self.bytes(value.syncPayloadBytes))")]
        if value.exceededBytes > 0 { lines.append(L10n.text("已超出 \(Self.bytes(value.exceededBytes))；已有内容保留，停止进一步增长。")) }
        quotaDetail.stringValue = lines.joined(separator: "\n")
        if let draftGeneration, draftGeneration == quotaDraftGeneration, !quotaDraftDirty {
            quotaMode.selectItem(at: value.limitBytes == nil ? 0 : 1)
            if let bytes = value.limitBytes {
                let mib: Int64 = 1_048_576
                quotaMiB.stringValue = String(bytes / mib + (bytes % mib == 0 ? 0 : 1))
            } else { quotaMiB.stringValue = "" }
        }
        renderControls()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === quotaMiB else { return }
        changeQuotaDraft()
    }

    @objc private func changeQuotaDraft() {
        quotaDraftGeneration &+= 1; quotaDraftDirty = true
        quotaNotice.stringValue = L10n.text("上限尚未保存。")
        renderControls()
    }

    /// MiB is exact binary scaling. Reject fractions, signs, zero and overflow before dispatch.
    static func contentQuotaBytes(limited: Bool, text: String) throws -> Int64? {
        guard limited else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let mib = Int64(text), mib > 0, mib <= Int64.max / 1_048_576 else { throw ContentQuotaError.invalidLimit }
        return mib * 1_048_576
    }

    @objc func saveContentQuota() {
        guard !isBusy, quotaDraftDirty, let previous = contentQuota, let save = actions.setContentQuota else { return }
        guard allowsLimitChange?() != false else {
            quotaNotice.stringValue = L10n.text("其他修改正在进行，请稍后重试。"); return
        }
        let limit: Int64?
        do { limit = try Self.contentQuotaBytes(limited: quotaMode.indexOfSelectedItem == 1, text: quotaMiB.stringValue) }
        catch { quotaNotice.stringValue = L10n.text("请输入大于零的 MiB 整数，或选择不限。"); return }
        let current = begin(.savingLimit, message: L10n.text("正在保存数据上限；关闭窗口不会撤销已开始的保存。"))
        let presentation = presentationGeneration, draft = quotaDraftGeneration
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await save(limit, previous.policyRevision)
                if self.acceptsQuotaReceipt(current, presentation: presentation) {
                    if self.quotaDraftGeneration == draft { self.quotaDraftDirty = false }
                    self.displayQuota(value, draftGeneration: draft)
                    self.quotaNotice.stringValue = L10n.text("保存数据上限已更新；已有内容保留。待保存内容需要在菜单中明确重试。")
                    self.status.stringValue = L10n.text("保存数据用量与上限已更新。")
                }
            } catch {
                if self.acceptsQuotaReceipt(current, presentation: presentation) {
                    if let quotaError = error as? ContentQuotaError, case .stalePolicy = quotaError {
                        self.contentQuota = nil
                        do {
                            if let read = self.actions.readContentQuota {
                                let latest = try await read()
                                if self.acceptsQuotaReceipt(current, presentation: presentation) { self.displayQuota(latest) }
                            }
                        } catch {
                            if self.acceptsQuotaReceipt(current, presentation: presentation) {
                                self.quotaDetail.stringValue = L10n.text("无法读取保存数据用量与上限，未将未知用量显示为零。\n\(error.localizedDescription)")
                            }
                        }
                        if self.acceptsQuotaReceipt(current, presentation: presentation) {
                            self.quotaNotice.stringValue = L10n.text("上限已在其他窗口或进程中改变。你的输入仍保留；请核对当前上限后再次保存。")
                        }
                    } else {
                        self.quotaNotice.stringValue = L10n.text("上限未保存，输入仍保留。\n\(error.localizedDescription)")
                    }
                    if self.acceptsQuotaReceipt(current, presentation: presentation) { self.status.stringValue = L10n.text("上限未保存。") }
                }
            }
            // Closing/suspending invalidates presentation only. An already dispatched commit
            // must settle and unblock quit/restart, even when its UI receipt is obsolete.
            let obsolete = self.presentationGeneration != presentation
            if obsolete { self.contentQuota = nil }
            self.finish(current)
            if obsolete, self.window?.isVisible == true, self.allowsLibraryScan?() != false { self.refresh() }
        }
    }

    private func acceptsQuotaReceipt(_ current: UInt64, presentation: UInt64) -> Bool {
        accepts(current) && presentationGeneration == presentation && allowsLibraryScan?() != false
    }

    @objc func cleanup() { prepareCleanup(automatic: false) }
    private func prepareCleanup(automatic automaticRun: Bool) {
        guard canBegin() else { if automaticRun { automaticQueued = true }; return }
        let current = begin(.preparing, message: L10n.text("正在准备可回收文件范围…"))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let plan = try await self.actions.prepare()
                guard self.accepts(current) else { return }
                self.display(plan.usage)
                guard plan.candidateCount > 0 else {
                    self.status.stringValue = L10n.text("当前没有通过验证的可回收文件。受保护或待检查内容继续保留。")
                    self.finish(current); return
                }
                if automaticRun {
                    guard self.preferences.bool(forKey: "automaticallyReclaimOwnedFiles") else {
                        self.status.stringValue = L10n.text("自动回收已关闭，未开始回收文件。"); self.finish(current); return
                    }
                    self.commit(plan, generation: current, automaticRun: true); return
                }
                self.setPhase(.confirming)
                self.status.stringValue = L10n.text("等待确认；文件尚未移除。")
                let decide: (Bool) -> Void = { [weak self] accepted in
                    guard let self, self.accepts(current), self.phase == .confirming else { return }
                    self.cancelConfirmation = nil
                    if accepted { self.commit(plan, generation: current) }
                    else { self.status.stringValue = L10n.text("已取消，未回收文件。"); self.finish(current) }
                }
                let dismiss = self.confirmation?(plan, decide) ?? self.showConfirmation(plan, completion: decide)
                if self.accepts(current), self.phase == .confirming { self.cancelConfirmation = dismiss }
            } catch {
                guard self.accepts(current) else { return }
                self.detail.stringValue = L10n.text("无法准备回收范围，文件尚未删除。\n\(error.localizedDescription)")
                self.status.stringValue = L10n.text("无法准备回收范围，原因见下方。")
                self.finish(current)
            }
        }
    }
    private func commit(_ plan: OwnedStorageCleanupPlan, generation current: UInt64, automaticRun: Bool = false) {
        guard accepts(current) else { return }
        guard isExternalMutationBusy?() != true else {
            if automaticRun { automaticQueued = true }
            status.stringValue = automaticRun ? L10n.text("其他修改正在进行，自动回收将延后重新核对。") : L10n.text("其他修改正在进行，未开始回收；请稍后重新准备范围。")
            finish(current); return
        }
        setPhase(.committing); status.stringValue = L10n.text("正在回收已确认的文件；关闭窗口不会中断已开始的提交。")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.complete(try await self.actions.commit(plan), generation: current) }
            catch { self.failedCommit(error, generation: current) }
        }
    }
    @objc func recover() {
        guard canBegin() else { recoveryQueued = true; return }
        let current = begin(.recovering, message: L10n.text("正在恢复中断的回收；只处理已有日志范围…"))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.complete(try await self.actions.recover(), generation: current) }
            catch { self.failedCommit(error, generation: current) }
        }
    }
    private func complete(_ result: OwnedStorageCleanupResult, generation current: UInt64) async throws {
        guard accepts(current) else { return }
        let presentation = presentationGeneration, draft = quotaDraftGeneration
        invalidateLibraryUsage()
        let message = L10n.text("已移除 \(result.removedAssetCount) 组、\(result.removedFileCount) 个文件，文件大小合计 \(Self.bytes(result.removedLogicalBytes))。") +
            (result.remainingPendingCount > 0 ? L10n.text("另有 \(result.remainingPendingCount) 组仍待继续处理。") : "")
        do { let report = try await actions.scan(); if accepts(current) { display(report) } }
        catch {
            guard accepts(current) else { return }
            usage = nil; detail.stringValue = L10n.text("文件回收结果已返回，但最新占用读取失败；请刷新。")
        }
        if let read = actions.readContentQuota {
            do {
                let latest = try await read()
                if acceptsQuotaReceipt(current, presentation: presentation) { displayQuota(latest, draftGeneration: draft) }
            } catch {
                if acceptsQuotaReceipt(current, presentation: presentation) {
                    quotaDetail.stringValue = L10n.text("无法读取保存数据用量与上限，未将未知用量显示为零。\n\(error.localizedDescription)")
                }
            }
        }
        guard accepts(current) else { return }
        status.stringValue = message
        if result.removedAssetCount > 0 || result.remainingPendingCount > 0 || window?.isVisible == true { onMessage?(message) }
        finish(current)
    }
    private func failedCommit(_ error: Error, generation current: UInt64) {
        guard accepts(current) else { return }
        invalidateLibraryUsage()
        usage = nil
        detail.stringValue = L10n.text("回收可能已处理部分文件。现有日志会用于恢复，不能把失败当作完全没有改变。\n\(error.localizedDescription)")
        status.stringValue = L10n.text("回收尚未完成，可继续中断的回收；原因见下方。")
        onMessage?(status.stringValue); finish(current)
    }
    @objc private func changeAutomatic() {
        preferences.set(automatic.state == .on, forKey: "automaticallyReclaimOwnedFiles")
        if automatic.state == .on {
            status.stringValue = L10n.text("自动回收已开启：后台核对依赖后只处理不再使用、可验证的托管文件。")
            requestAutomaticReclamation()
        } else { automaticQueued = false; status.stringValue = L10n.text("自动回收已关闭；已经开始的回收会完成。") }
    }
    @objc private func manageExternalUses() {
        guard let read = actions.readExternalUses, let release = actions.releaseExternalUses, canBegin() else { return }
        let current = begin(.scanning, message: L10n.text("正在读取外部使用保留范围…"))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let publications = try await read()
                guard self.accepts(current) else { return }
                guard !publications.isEmpty else {
                    self.status.stringValue = L10n.text("当前没有需要人工确认的外部使用保护。"); self.finish(current); return
                }
                guard let window = self.window, window.isVisible else { self.finish(current); return }
                let paths = publications.flatMap { publication in
                    publication.fileURLs.map { "[" + Self.purposeLabel(publication.purpose) + "] " + $0.path }
                }.sorted()
                let alert = NSAlert(); alert.messageText = L10n.text("确认这些文件已不再被外部使用？")
                alert.informativeText = L10n.text("拖出、系统分享及外部打开后，应用无法确认接收方何时读完；旧版本的输出也缺少记录。只有确认下列文件不再被其他应用使用时，才解除这些保护。当前版本的剪贴板保护由实际剪贴板状态管理，不在此次解除范围。\n\n仍被历史、撤销或同步依赖的文件继续保留；其余文件将可被手动回收，或在已开启自动回收时由后台处理。范围包含 \(paths.count) 项文件使用记录：")
                let text = NSTextView(); text.isEditable = false; text.isSelectable = true
                text.string = paths.joined(separator: "\n")
                text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
                scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = text
                text.frame = NSRect(x: 0, y: 0, width: 520, height: 180)
                text.isVerticallyResizable = true; text.isHorizontallyResizable = true
                alert.accessoryView = scroll
                alert.addButton(withTitle: L10n.text("继续保留")); alert.addButton(withTitle: L10n.text("确认已不再使用，解除保护"))
                self.setPhase(.confirming)
                alert.beginLocalizedSheetModal(for: window) { [weak self] response in
                    guard let self, self.accepts(current), self.phase == .confirming else { return }
                    self.cancelConfirmation = nil
                    guard response == .alertSecondButtonReturn else {
                        self.status.stringValue = L10n.text("外部使用保护保持不变。"); self.finish(current); return
                    }
                    guard self.isExternalMutationBusy?() != true else {
                        self.status.stringValue = L10n.text("其他修改正在进行，保护未解除，请稍后重新核对。"); self.finish(current); return
                    }
                    self.setPhase(.committing)
                    self.task = Task { @MainActor in
                        do {
                            try await release(Set(publications.map(\.id)))
                            guard self.accepts(current) else { return }
                            self.usage = nil; self.detail.stringValue = L10n.text("所确认的外部使用保护已解除，请刷新查看仍受其他依赖保护的内容。")
                            if self.actions.scanLibrary != nil { self.invalidateManagedUsage() }
                            self.status.stringValue = L10n.text("保护已解除；这一步没有删除文件。")
                        } catch {
                            guard self.accepts(current) else { return }
                            self.status.stringValue = L10n.text("未解除外部使用保护，原因见下方。")
                            self.detail.stringValue = error.localizedDescription
                        }
                        self.finish(current)
                    }
                }
                self.cancelConfirmation = { [weak window, weak alert] in
                    if let window, let alert, alert.window.sheetParent === window { window.endSheet(alert.window, returnCode: .abort) }
                }
            } catch {
                guard self.accepts(current) else { return }
                self.status.stringValue = L10n.text("外部使用保护读取失败，原因见下方。")
                self.detail.stringValue = error.localizedDescription; self.finish(current)
            }
        }
    }
    private func showConfirmation(_ plan: OwnedStorageCleanupPlan, completion: @escaping (Bool) -> Void) -> () -> Void {
        guard let window, window.isVisible else { completion(false); return {} }
        let alert = NSAlert(); alert.messageText = L10n.text("回收不再使用的托管文件？")
        alert.informativeText = L10n.text("已核对 \(plan.candidateCount) 组，文件大小合计 \(Self.bytes(plan.candidateLogicalBytes))。执行前会再次核对同一范围；受保护内容、修改过的副本、外部原文件和备份会保留。文件回收不可撤销，也不等于磁盘空间会立即增加同样大小。")
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("确认回收"))
        alert.beginLocalizedSheetModal(for: window) { response in completion(response == .alertSecondButtonReturn) }
        return { [weak window, weak alert] in
            if let window, let alert, alert.window.sheetParent === window { window.endSheet(alert.window, returnCode: .abort) }
        }
    }
    private func display(_ report: OwnedStorageUsage) {
        usage = report
        let partial = report.measurementComplete ? "" : L10n.text("部分路径无法计量或扫描达到边界，下面的大小仅是已计量的下界。\n\n")
        detail.stringValue = partial + L10n.text("托管文件：\(report.assetCount) 组\n原件与打开副本大小：\(Self.bytes(report.totalLogicalBytes))\n文件系统分配字节：\(Self.bytes(report.totalAllocatedBytes))\n可回收：\(report.reclaimableAssetCount) 组 · \(Self.bytes(report.reclaimableLogicalBytes))\n有使用依赖：\(report.protectedAssetCount) 组\n待检查并保留：\(report.unverifiedAssetCount) 项\n其中旧版本外部使用保护：\(report.legacyProtectedAssetCount) 组\n中断后待处理：\(report.pendingReclamationCount) 组")
    }
    private func invalidateLibraryUsage() {
        if actions.readContentQuota != nil {
            contentQuota = nil
            quotaDetail.stringValue = L10n.text("尚未读取，不能据此判断为零。")
        }
        guard actions.scanLibrary != nil else { return }
        libraryUsage = nil
        libraryDetail.stringValue = L10n.text("文件已发生变化，请刷新整库占用。")
    }
    private func invalidateManagedUsage() {
        usage = nil
        detail.stringValue = L10n.text("托管文件的保留依赖尚未核对。点击“清理可回收文件…”可查看本次范围，确认前不会删除文件。")
    }
    private func canBegin() -> Bool {
        guard !isBusy else { return false }
        guard isExternalMutationBusy?() != true else { status.stringValue = L10n.text("其他修改正在进行，请稍后重试。"); return false }
        return true
    }
    private func begin(_ phase: Phase, message: String) -> UInt64 {
        generation &+= 1; setPhase(phase); status.stringValue = message; return generation
    }
    private func accepts(_ current: UInt64) -> Bool { current == generation && !Task.isCancelled }
    private func finish(_ current: UInt64) {
        guard current == generation else { return }
        task = nil; setPhase(.idle)
        DispatchQueue.main.async { [weak self] in self?.resumeDeferred() }
    }
    private func setPhase(_ next: Phase) {
        let wasBusy = isBusy; phase = next; renderControls()
        if wasBusy != isBusy { onBusyChanged?(isBusy) }
    }
    private func renderControls() {
        refreshButton.isEnabled = !isBusy; cleanupButton.isEnabled = !isBusy
        recoverButton.isEnabled = !isBusy
        automatic.isEnabled = !isBusy
        externalUsesButton.isEnabled = !isBusy && actions.readExternalUses != nil && actions.releaseExternalUses != nil
        quotaMode.isEnabled = !isCommitting
        quotaMiB.isEnabled = !isCommitting && quotaMode.indexOfSelectedItem == 1
        quotaSave.isEnabled = !isBusy && contentQuota != nil && quotaDraftDirty && actions.setContentQuota != nil
    }
    private static func purposeLabel(_ purpose: OwnedAssetPublicationPurpose) -> String {
        switch purpose {
        case .legacyExternal: return L10n.text("旧版本保留")
        case .externalOpen: return L10n.text("外部打开")
        case .sharing: return L10n.text("系统分享")
        case .drag: return L10n.text("拖出")
        case .clipboard: return L10n.text("当前剪贴板")
        }
    }
    private static func bytes(_ value: Int64) -> String { L10n.fileSize(value) }
}
