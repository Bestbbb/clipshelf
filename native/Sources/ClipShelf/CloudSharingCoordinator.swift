import ClipShelfLocalization
import ClipShelfCore
import Foundation

/// Explicit lifecycle actions for shared copies. UI owns confirmation and invitation distribution.
actor CloudSharingCoordinator {
    private let store: HistoryStore
    private let transport: any SharedBoardLifecycleTransport
    private let synchronizer: SharedBoardCoordinator
    private var accountID: String?

    init(store: HistoryStore, transport: any SharedBoardLifecycleTransport) {
        self.store = store
        self.transport = transport
        synchronizer = SharedBoardCoordinator(store: store, transport: transport)
    }

    func enable(expectedAccountID: String? = nil) async throws -> String {
        let account = try await transport.resolveAccount(expectedAccountID: expectedAccountID)
        try store.configureSharing(accountID: account)
        accountID = account
        return account
    }

    func disable() throws {
        accountID = nil
        try store.configureSharing(accountID: nil)
    }

    func states() throws -> [SharedBoardState] {
        guard let accountID else { return [] }
        return try store.sharedBoards(accountID: accountID)
    }

    func createSharedCopy(boardID: UUID, allowEditing: Bool = false) async throws -> SharedBoardDescriptor {
        let account = try requireEnabledAccount()
        guard let source = try store.pinboards().first(where: { $0.id == boardID }) else { throw HistoryStoreError.pinboardNotFound }
        let descriptor = try await transport.createShare(boardID: UUID(), title: source.name,
                                                        allowEditing: allowEditing, expectedAccountID: account)
        do {
            guard try requireEnabledAccount() == account else { throw SharedBoardError.accountChanged }
            try store.createSharedCopy(from: source.id, descriptor: descriptor)
        } catch {
            // No clipboard content has been uploaded yet; remove the newly-created empty invitation when possible.
            try? await transport.stopSharing(descriptor)
            throw error
        }
        _ = try await synchronizer.synchronize(descriptor)
        return descriptor
    }

    func acceptShare(url: URL) async throws -> SharedBoardDescriptor {
        let account = try requireEnabledAccount()
        let descriptor = try await transport.acceptShare(url: url, expectedAccountID: account)
        guard try requireEnabledAccount() == account else { throw SharedBoardError.accountChanged }
        let access = try await transport.access(for: descriptor)
        guard try requireEnabledAccount() == account else { throw SharedBoardError.accountChanged }
        guard access != .revoked else { throw SharedBoardError.revoked }
        try store.registerSharedBoard(descriptor, access: access)
        _ = try await synchronizer.synchronize(descriptor)
        return descriptor
    }

    func synchronize(boardID: UUID) async throws -> SyncRunSummary {
        let state = try state(boardID)
        return try await synchronizer.synchronize(state.descriptor)
    }

    func synchronizeAll() async -> [UUID: String] {
        guard let states = try? states() else { return [:] }
        var failures: [UUID: String] = [:]
        for state in states where state.access != .revoked {
            do { _ = try await synchronizer.synchronize(state.descriptor) }
            catch { failures[state.id] = error.localizedDescription }
        }
        return failures
    }

    func invitationURL(boardID: UUID) throws -> URL? { try state(boardID).descriptor.shareURL }

    func updateLinkPermission(boardID: UUID, allowEditing: Bool) async throws {
        let state = try state(boardID)
        guard state.access == .owner else { throw SharedBoardError.readOnly }
        try await transport.updateLinkPermission(board: state.descriptor, allowEditing: allowEditing)
    }

    func stopSharing(boardID: UUID, keepLocalCopy: Bool = true) async throws {
        let state = try state(boardID)
        guard state.access == .owner else { throw SharedBoardError.readOnly }
        // Capture a complete local copy before the server action if the user chose to keep one.
        if keepLocalCopy { _ = try store.copyBoardToLocal(boardID: boardID) }
        try await transport.stopSharing(state.descriptor)
        try finishLeaving(state, reason: L10n.text("所有者已停止共享"))
    }

    /// The system sharing presenter already deleted the CKShare. Never issue another cloud deletion.
    func sharingStoppedExternally(boardID: UUID, keepLocalCopy: Bool = true) throws {
        let state = try state(boardID)
        guard state.access != .revoked else { return }
        guard state.access == .owner else { throw SharedBoardError.readOnly }
        if keepLocalCopy, try store.pinboards().contains(where: { $0.id == boardID }) {
            _ = try store.copyBoardToLocal(boardID: boardID)
        }
        try finishLeaving(state, reason: L10n.text("已通过系统分享窗口停止共享"))
    }

    func leave(boardID: UUID, keepLocalCopy: Bool = false) async throws {
        let state = try state(boardID)
        guard state.access != .owner else { throw SharedBoardError.readOnly }
        if keepLocalCopy { _ = try store.copyBoardToLocal(boardID: boardID) }
        try await transport.leave(state.descriptor)
        try finishLeaving(state, reason: L10n.text("已退出共享板"))
    }

    func failedDrafts(boardID: UUID) throws -> [FailedSharedDraft] {
        try store.failedSharedDrafts(boardID: boardID, accountID: requireEnabledAccount())
    }

    @discardableResult
    func recoverDraft(operationID: UUID, boardID: UUID) throws -> ClipboardRecord {
        try store.recoverFailedSharedDraft(operationID: operationID, boardID: boardID, accountID: requireEnabledAccount())
    }

    private func finishLeaving(_ state: SharedBoardState, reason: String) throws {
        guard try requireEnabledAccount() == state.descriptor.accountID else { throw SharedBoardError.accountChanged }
        try store.updateSharedAccess(boardID: state.id, accountID: state.descriptor.accountID, access: .revoked)
        try store.rejectPendingSharedEdits(boardID: state.id, accountID: state.descriptor.accountID,
                                          reason: reason, clearCachedContent: true)
    }

    private func state(_ boardID: UUID) throws -> SharedBoardState {
        let account = try requireEnabledAccount()
        guard let state = try store.sharedBoards(accountID: account).first(where: { $0.id == boardID }) else { throw SharedBoardError.notRegistered }
        return state
    }

    private func requireEnabledAccount() throws -> String {
        guard let accountID, try store.sharingConfiguration().accountID == accountID else { throw SharedBoardError.accountChanged }
        return accountID
    }
}
