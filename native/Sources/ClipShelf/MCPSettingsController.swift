import ClipShelfLocalization
import AppKit
import ClipShelfCore

@MainActor
final class MCPSettingsController: NSWindowController {
    private let store: HistoryStore
    private let authorization: MCPAuthorizationStore
    private let server: MCPServer
    private let router: MCPToolRouter
    private let status = NSTextField(wrappingLabelWithString: L10n.text("MCP 默认关闭。开启后，仅接受这台 Mac 上已授权客户端的请求。"))
    private let endpoint = NSTextField(string: "")
    private let toggle = NSButton(title: L10n.text("开启本地 MCP"), target: nil, action: nil)
    private let clientRows = NSStackView()
    var onDataChanged: (() -> Void)?
    var onCredentialCopied: (() -> Void)?

    init(store: HistoryStore) throws {
        self.store = store
        authorization = try MCPAuthorizationStore()
        router = MCPToolRouter(store: store, authorizationStore: authorization)
        server = MCPServer(router: router, authorizationStore: authorization)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("ClipShelf · MCP 与 AI 工具")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        router.onDataChanged = { [weak self] in self?.onDataChanged?() }
        server.onChange = { [weak self] in self?.refresh() }
        authorization.onChange = { [weak self] in self?.refresh() }
        server.onAuthorizationRequest = { [weak self] request in await self?.approveOAuth(request) }
        toggle.target = self; toggle.action = #selector(toggleServer)
        endpoint.isEditable = false; endpoint.isSelectable = true
        endpoint.placeholderString = L10n.text("开启后显示服务地址")
        endpoint.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let disclosure = NSTextField(wrappingLabelWithString: L10n.text("AI 工具可以把它读取的内容发送给其模型服务。请按工具分别选择读取、修改、删除权限和可访问的历史或分组；撤销会阻止后续请求。"))
        disclosure.textColor = .secondaryLabelColor
        let add = NSButton(title: L10n.text("授权新工具…"), target: self, action: #selector(addClient))
        let toolbar = NSStackView(views: [toggle, add]); toolbar.spacing = 12
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        clientRows.orientation = .vertical; clientRows.alignment = .leading; clientRows.spacing = 8
        clientRows.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = clientRows
        let body = NSStackView(views: [status, endpoint, disclosure, toolbar, scroll])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        body.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = body
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(greaterThanOrEqualToConstant: 600), body.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            endpoint.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -44),
            disclosure.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -44),
            status.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -44),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -44), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            clientRows.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -18)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() { window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func stop() { server.stop() }

    private func refresh() {
        endpoint.stringValue = server.endpointURL?.absoluteString ?? ""
        toggle.title = server.isRunning ? L10n.text("关闭 MCP") : L10n.text("开启本地 MCP")
        status.stringValue = server.isRunning ? L10n.text("本地服务运行中 · 仅监听 127.0.0.1 · 所有读取与修改都需授权") : L10n.text("MCP 已关闭，AI 工具无法访问。授权仍可单独管理。")
        for view in clientRows.arrangedSubviews { clientRows.removeArrangedSubview(view); view.removeFromSuperview() }
        if authorization.clients.isEmpty { clientRows.addArrangedSubview(NSTextField(labelWithString: L10n.text("尚未授权任何工具"))) }
        for (index, client) in authorization.clients.enumerated() {
            let permissions = Self.permissionSummary(client.permissions)
            let scope = [client.scope.includeHistory ? L10n.text("未固定历史") : nil,
                         client.scope.allPinboards ? L10n.text("全部分组") : L10n.text("\(client.scope.pinboardIDs.count) 个分组")].compactMap { $0 }.joined(separator: " · ")
            let label = NSTextField(wrappingLabelWithString: "\(client.name)\n\(permissions) · \(scope)")
            let revoke = NSButton(title: L10n.text("撤销"), target: self, action: #selector(revokeClient(_:)))
            revoke.tag = index
            let row = NSStackView(views: [label, revoke]); row.spacing = 12
            clientRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: clientRows.widthAnchor).isActive = true
        }
    }

    static func permissionSummary(_ permissions: Set<MCPAuthorizationStore.Permission>) -> String {
        permissions.sorted { $0.rawValue < $1.rawValue }.map { permission in
            switch permission {
            case .read: return L10n.text("读取")
            case .write: return L10n.text("新增与修改")
            case .delete: return L10n.text("删除")
            }
        }.joined(separator: " / ")
    }

    @objc private func toggleServer() {
        if server.isRunning { server.stop(); refresh(); return }
        toggle.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.toggle.isEnabled = true }
            do { _ = try await self.server.start(port: 44723); self.refresh() }
            catch { self.presentError(L10n.text("无法启动 MCP"), detail: L10n.text("本地端口 44723 可能已被占用。现有授权保留，服务未开启。")) }
        }
    }

    @objc private func addClient() {
        let alert = NSAlert(); alert.messageText = L10n.text("授权一个 AI 工具")
        alert.informativeText = L10n.text("令牌只显示一次。选择该工具可以操作的内容；未勾选的范围不会授权。")
        let name = NSTextField(string: ""); name.placeholderString = L10n.text("工具名称，例如 Codex")
        let read = NSButton(checkboxWithTitle: L10n.text("读取"), target: nil, action: nil); read.state = .on
        let write = NSButton(checkboxWithTitle: L10n.text("新增与修改"), target: nil, action: nil)
        let delete = NSButton(checkboxWithTitle: L10n.text("删除"), target: nil, action: nil)
        let history = NSButton(checkboxWithTitle: L10n.text("允许访问未固定的历史内容"), target: nil, action: nil)
        let allBoards = NSButton(checkboxWithTitle: L10n.text("允许访问全部分组（包括之后创建的分组）"), target: nil, action: nil)
        let permissions = NSStackView(views: [read, write, delete]); permissions.spacing = 12
        let body = NSStackView(views: [name, permissions, history, allBoards]); body.orientation = .vertical; body.alignment = .leading; body.spacing = 8
        let boards = (try? store.pinboards()) ?? []
        let choices: [(Pinboard, NSButton)] = boards.map { board in
            let button = NSButton(checkboxWithTitle: board.name, target: nil, action: nil)
            body.addArrangedSubview(button); return (board, button)
        }
        body.frame = NSRect(x: 0, y: 0, width: 450, height: 130 + boards.count * 26)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: min(400, 130 + boards.count * 26)))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = body
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("创建授权"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        var grants = Set<MCPAuthorizationStore.Permission>()
        if read.state == .on { grants.insert(.read) }
        if write.state == .on { grants.insert(.write) }
        if delete.state == .on { grants.insert(.delete) }
        let scope = MCPAuthorizationStore.AccessScope(includeHistory: history.state == .on,
            allPinboards: allBoards.state == .on, pinboardIDs: Set(choices.filter { $0.1.state == .on }.map { $0.0.id }))
        do {
            let issued = try authorization.authorizeClient(name: name.stringValue, permissions: grants, scope: scope)
            presentCredential(issued)
            refresh()
        } catch { presentError(L10n.text("未能创建授权"), detail: L10n.text("请填写名称、选择权限和至少一个内容范围。若设置无误，请检查本机钥匙串。")) }
    }

    private func presentCredential(_ issued: MCPAuthorizationStore.IssuedClient) {
        let alert = NSAlert(); alert.messageText = L10n.text("\(issued.client.name) 的访问令牌")
        alert.informativeText = L10n.text("将此令牌配置为本地 MCP 请求的 Bearer token，或用于 stdio 桥的 CLIPSHELF_MCP_TOKEN。关闭后无法再次查看，可撤销后重新授权。")
        let token = NSSecureTextField(string: issued.token); token.frame = NSRect(x: 0, y: 0, width: 450, height: 24)
        alert.accessoryView = token
        alert.addButton(withTitle: L10n.text("完成")); alert.addButton(withTitle: L10n.text("复制令牌"))
        if alert.runModal() == .alertSecondButtonReturn {
            let item = NSPasteboardItem()
            item.setString(issued.token, forType: .string)
            item.setString("", forType: .init("org.nspasteboard.ConcealedType"))
            item.setString(UUID().uuidString, forType: CaptureService.internalType)
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item])
            onCredentialCopied?()
        }
    }

    @objc private func revokeClient(_ sender: NSButton) {
        let clients = authorization.clients
        guard clients.indices.contains(sender.tag) else { return }
        let client = clients[sender.tag]
        do { try authorization.revoke(id: client.id); server.revokeSessions(for: client.id); refresh() }
        catch { presentError(L10n.text("撤销失败"), detail: L10n.text("未能保存钥匙串更改。可以先关闭 MCP 服务，立即停止后续访问。")) }
    }

    private func presentError(_ title: String, detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        alert.runModal()
    }

    private func approveOAuth(_ request: MCPOAuthAuthorizationRequest) async -> MCPOAuthApproval? {
        guard !Task.isCancelled, Date() < request.expiresAt, let window else { return nil }
        present()
        let alert = NSAlert(); alert.messageText = L10n.text("允许这个本地工具连接 ClipShelf？")
        alert.informativeText = L10n.text("工具自报名称：\(request.clientName)（未验证身份）\n回调地址：\(request.redirectURI.absoluteString)\n服务：\(request.resource.absoluteString)\n\n工具可能把读取的内容发送给其模型服务。请选择内容范围；只授予本次勾选的权限。")
        let read = NSButton(checkboxWithTitle: L10n.text("读取"), target: nil, action: nil); read.state = .on
        let write = NSButton(checkboxWithTitle: L10n.text("新增与修改"), target: nil, action: nil)
        let delete = NSButton(checkboxWithTitle: L10n.text("删除"), target: nil, action: nil)
        write.isEnabled = request.requestedPermissions.contains(.write)
        delete.isEnabled = request.requestedPermissions.contains(.delete)
        let history = NSButton(checkboxWithTitle: L10n.text("未固定的历史内容"), target: nil, action: nil)
        let allBoards = NSButton(checkboxWithTitle: L10n.text("全部分组（包括之后创建的分组）"), target: nil, action: nil)
        let rows = NSStackView(views: [NSStackView(views: [read, write, delete]), history, allBoards])
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        let boards = (try? store.pinboards()) ?? []
        let choices = boards.map { board -> (UUID, NSButton) in
            let button = NSButton(checkboxWithTitle: board.name, target: nil, action: nil)
            rows.addArrangedSubview(button); return (board.id, button)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: min(350, 110 + boards.count * 28)))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        rows.frame = NSRect(x: 0, y: 0, width: 460, height: 110 + boards.count * 28); scroll.documentView = rows
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.text("拒绝")); alert.addButton(withTitle: L10n.text("允许所选范围"))
        let response: NSApplication.ModalResponse = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in
                if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .cancel) }
            }
        }
        guard response == .alertSecondButtonReturn, !Task.isCancelled, Date() < request.expiresAt else { return nil }
        var permissions = Set<MCPAuthorizationStore.Permission>()
        if read.state == .on { permissions.insert(.read) }
        if write.isEnabled, write.state == .on { permissions.insert(.write) }
        if delete.isEnabled, delete.state == .on { permissions.insert(.delete) }
        let scope = MCPAuthorizationStore.AccessScope(includeHistory: history.state == .on, allPinboards: allBoards.state == .on,
            pinboardIDs: Set(choices.filter { $0.1.state == .on }.map(\.0)))
        return MCPOAuthApproval(permissions: permissions, scope: scope)
    }
}
