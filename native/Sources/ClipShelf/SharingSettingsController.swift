import AppKit
import ClipShelfCore

@MainActor
final class SharingSettingsController: NSWindowController {
    private let store: HistoryStore
    private let transport = CloudSharedBoardTransport()
    private let coordinator: CloudSharingCoordinator
    private let sharingPresenter: CloudSharedBoardSharingPresenter
    private let preferences: UserDefaults
    private let status = NSTextField(wrappingLabelWithString: "共享板默认关闭。私人历史不会随共享板公开。")
    private let toggle = NSButton(title: "开启共享板…", target: nil, action: nil)
    private let create = NSButton(title: "创建共享副本…", target: nil, action: nil)
    private let join = NSButton(title: "接受邀请…", target: nil, action: nil)
    private let rows = NSStackView()
    private var states: [SharedBoardState] = []
    private var enabled = false
    private var busy = false
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pendingExternalStops = Set<UUID>()
    var onDataChanged: (() -> Void)?
    var onCopyLink: ((URL) -> Void)?

    init(store: HistoryStore, preferences: UserDefaults = .standard) {
        self.store = store; self.preferences = preferences
        coordinator = CloudSharingCoordinator(store: store, transport: transport)
        sharingPresenter = CloudSharedBoardSharingPresenter(transport: transport)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 450),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ClipShelf · 共享板"; window.isReleasedWhenClosed = false
        super.init(window: window)
        sharingPresenter.onChange = { [weak self] _ in self?.synchronize() }
        sharingPresenter.onError = { [weak self] error in self?.status.stringValue = "成员管理未完成：\(error.localizedDescription)" }
        sharingPresenter.onStopSharing = { [weak self] board in
            self?.pendingExternalStops.insert(board.boardID)
            self?.drainExternalStops()
        }
        toggle.target = self; toggle.action = #selector(toggleSharing)
        create.target = self; create.action = #selector(createShare)
        join.target = self; join.action = #selector(joinShare)
        create.isEnabled = false; join.isEnabled = false; toggle.isEnabled = false
        let description = NSTextField(wrappingLabelWithString: "共享会创建独立副本，原私有分组保留。持有邀请链接的 Apple Account 用户可按设定权限访问该共享副本；链接需由你自行发送。共享和私人历史同步是独立开关。")
        description.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [toggle, create, join]); controls.spacing = 12
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = rows
        let body = NSStackView(views: [status, description, controls, scroll])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 18
        body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24); window.contentView = body
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(greaterThanOrEqualToConstant: 680), body.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            status.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -48), description.widthAnchor.constraint(equalTo: status.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: status.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -18)
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .unavailable(let reason) = await self.transport.configurationStatus() { self.status.stringValue = reason }
            else { self.toggle.isEnabled = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() { window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func resumeIfEnabled() {
        guard preferences.bool(forKey: "sharingEnabled"), let account = preferences.string(forKey: "sharingAccount") else { return }
        enable(expectedAccount: account)
    }
    func stop() { generation &+= 1; task?.cancel(); timer?.invalidate(); timer = nil }

    func offerInvitation(_ url: URL) {
        present()
        guard enabled else { status.stringValue = "请先开启共享板，再通过“接受邀请”粘贴邀请链接。"; return }
        confirmJoin(url)
    }

    @objc private func toggleSharing() {
        if enabled {
            stop(); busy = false
            perform {
                try await self.coordinator.disable()
                self.enabled = false; self.preferences.set(false, forKey: "sharingEnabled")
                self.status.stringValue = "本机共享传输已关闭。已共享的云端内容继续存在；停止共享需单独操作。"
            }
            return
        }
        guard !busy else { return }
        let alert = NSAlert(); alert.messageText = "开启这台 Mac 的共享板？"
        alert.informativeText = "将连接系统设置中当前的 Apple Account。此时不会分享任何私有历史；创建共享副本和接受邀请分别需要你操作。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "开启")
        if alert.runModal() == .alertSecondButtonReturn { enable(expectedAccount: nil) }
    }

    private func enable(expectedAccount: String?) {
        perform {
            let account = try await self.coordinator.enable(expectedAccountID: expectedAccount)
            self.enabled = true; self.preferences.set(true, forKey: "sharingEnabled"); self.preferences.set(account, forKey: "sharingAccount")
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronize() }
            }
            self.status.stringValue = "共享已开启。选择分组创建共享副本，或接受邀请。"
        }
    }

    @objc private func createShare() {
        guard enabled, !busy else { return }
        let sharedIDs = Set(states.map(\.id))
        let boards = ((try? store.pinboards()) ?? []).filter { !sharedIDs.contains($0.id) }
        guard !boards.isEmpty else { status.stringValue = "请先在主面板创建一个私有分组并加入内容。"; return }
        let alert = NSAlert(); alert.messageText = "创建独立共享副本"
        alert.informativeText = "所选分组的当前内容会复制到新共享板并上传，原私有分组保留。后续编辑分别保存，不自动合并两个分组。"
        let board = NSPopUpButton(); board.addItems(withTitles: boards.map(\.name))
        let edit = NSButton(checkboxWithTitle: "允许持有链接的参与者编辑（默认只读）", target: nil, action: nil)
        let body = NSStackView(views: [board, edit]); body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        body.frame = NSRect(x: 0, y: 0, width: 440, height: 75); alert.accessoryView = body
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "创建并上传")
        guard alert.runModal() == .alertSecondButtonReturn, boards.indices.contains(board.indexOfSelectedItem) else { return }
        let id = boards[board.indexOfSelectedItem].id, allowEditing = edit.state == .on
        perform {
            _ = try await self.coordinator.createSharedCopy(boardID: id, allowEditing: allowEditing)
            self.status.stringValue = "共享副本已创建。请从分组操作中复制邀请链接；不会自动发送邀请。"
        }
    }

    @objc private func joinShare() {
        guard enabled, !busy else { return }
        let alert = NSAlert(); alert.messageText = "接受共享板邀请"
        alert.informativeText = "粘贴 CloudKit 邀请链接。接受后，共享内容会下载到这台 Mac。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 28)); field.placeholderString = "https://www.icloud.com/share/…"
        alert.accessoryView = field; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "接受")
        guard alert.runModal() == .alertSecondButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        accept(url)
    }

    private func confirmJoin(_ url: URL) {
        let alert = NSAlert(); alert.messageText = "接受收到的共享板邀请？"
        alert.informativeText = "将通过当前 Apple Account 接受此邀请并下载共享内容。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "接受")
        if alert.runModal() == .alertSecondButtonReturn { accept(url) }
    }

    private func accept(_ url: URL) {
        perform {
            _ = try await self.coordinator.acceptShare(url: url)
            self.status.stringValue = "已接受邀请，共享内容可在主面板分组中使用。"
        }
    }

    private func synchronize() {
        guard enabled, !busy else { return }
        perform {
            let errors = await self.coordinator.synchronizeAll()
            self.status.stringValue = errors.isEmpty ? "共享板已同步。" : "\(errors.count) 个共享板尚未同步：\(errors.values.first ?? "请稍后重试。")"
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; generation &+= 1; let current = generation
        create.isEnabled = false; join.isEnabled = false; toggle.isEnabled = enabled
        status.stringValue = "正在处理共享操作…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await action() }
            catch {
                guard current == self.generation else { return }
                self.status.stringValue = "共享操作未完成：\(error.localizedDescription)"
            }
            guard current == self.generation, !Task.isCancelled else { return }
            self.busy = false; self.toggle.isEnabled = true
            self.toggle.title = self.enabled ? "关闭本机共享传输" : "开启共享板…"
            self.create.isEnabled = self.enabled; self.join.isEnabled = self.enabled
            self.states = (try? await self.coordinator.states()) ?? []
            self.renderRows(); self.onDataChanged?()
            self.drainExternalStops()
        }
    }

    private func drainExternalStops() {
        guard !busy, enabled, let id = pendingExternalStops.first else { return }
        pendingExternalStops.remove(id)
        perform {
            try await self.coordinator.sharingStoppedExternally(boardID: id)
            self.status.stringValue = "系统已停止共享；可用缓存已保留为独立本地副本。"
        }
    }

    private func renderRows() {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let boards = (try? store.pinboards()) ?? []
        if states.isEmpty { rows.addArrangedSubview(NSTextField(labelWithString: "尚无共享板")) }
        for (index, state) in states.enumerated() {
            let role: String = switch state.access { case .owner: "所有者"; case .readWrite: "可编辑"; case .readOnly: "只读"; case .revoked: "已停止或被撤权" }
            let name = boards.first { $0.id == state.id }?.name ?? "共享板 \(state.id.uuidString.prefix(8))"
            let label = NSTextField(wrappingLabelWithString: "\(name) · \(role)")
            let menu = NSPopUpButton(frame: .zero, pullsDown: true); menu.tag = index
            menu.addItem(withTitle: "操作…")
            for (title, tag) in [("复制邀请链接", 1), ("立即同步", 2), ("恢复未提交草稿到本地", 3)] {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.tag = tag; menu.menu?.addItem(item)
            }
            if state.access == .owner {
                for (title, tag) in [("管理成员与邀请…", 8), ("链接参与者设为只读", 4), ("允许链接参与者编辑", 5), ("停止共享…", 6)] {
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.tag = tag; menu.menu?.addItem(item)
                }
            } else if state.access != .revoked {
                let item = NSMenuItem(title: "退出共享板…", action: nil, keyEquivalent: ""); item.tag = 7; menu.menu?.addItem(item)
            }
            menu.target = self; menu.action = #selector(boardAction(_:)); menu.autoenablesItems = false
            let row = NSStackView(views: [label, menu]); row.spacing = 12; rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    @objc private func boardAction(_ sender: NSPopUpButton) {
        guard !busy, enabled, states.indices.contains(sender.tag), let action = sender.selectedItem?.tag else { return }
        let state = states[sender.tag]
        var keepCopy = true
        if action == 5 || action == 6 || action == 7 {
            let alert = NSAlert(); alert.messageText = action == 5 ? "允许持有链接的参与者编辑？" : (action == 6 ? "停止共享这个板？" : "退出这个共享板？")
            alert.informativeText = action == 5 ? "持有链接的参与者可以修改和删除共享内容。" : "云端访问会改变。未提交修改会进入失败草稿，可单独恢复。"
            let keep = NSButton(checkboxWithTitle: "在本机保留一份独立副本", target: nil, action: nil); keep.state = .on
            if action != 5 { keep.frame = NSRect(x: 0, y: 0, width: 390, height: 28); alert.accessoryView = keep }
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            keepCopy = keep.state == .on
        }
        perform {
            switch action {
            case 1:
                if let url = try await self.coordinator.invitationURL(boardID: state.id) { self.onCopyLink?(url) }
                else { throw SyncError.unavailable("邀请链接尚不可用。") }
            case 2: _ = try await self.coordinator.synchronize(boardID: state.id)
            case 3:
                let drafts = try await self.coordinator.failedDrafts(boardID: state.id)
                for draft in drafts where draft.operation.record != nil {
                    _ = try await self.coordinator.recoverDraft(operationID: draft.id, boardID: state.id)
                }
            case 4, 5: try await self.coordinator.updateLinkPermission(boardID: state.id, allowEditing: action == 5)
            case 6: try await self.coordinator.stopSharing(boardID: state.id, keepLocalCopy: keepCopy)
            case 7: try await self.coordinator.leave(boardID: state.id, keepLocalCopy: keepCopy)
            case 8:
                guard let view = self.window?.contentView else { return }
                try await self.sharingPresenter.present(board: state.descriptor, relativeTo: view)
            default: return
            }
            self.status.stringValue = "操作已完成。"
        }
    }
}
