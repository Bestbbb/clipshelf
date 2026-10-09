import ClipShelfCore
import Foundation

/// A temporary queue of copy occurrences. Clipboard history may deduplicate records;
/// this queue deliberately does not. It never observes keys or writes the pasteboard.
@MainActor
final class StackCoordinator {
    enum Direction: String, CaseIterable {
        case forward
        case reverse
    }

    private(set) var queue: [ClipboardRecord] = []
    private(set) var isActive = false
    private(set) var sessionID = UUID()
    var direction: Direction = .forward {
        didSet {
            if oldValue != direction { onChange?() }
        }
    }
    var onChange: (() -> Void)?
    var retainer: (([ClipboardRecord]) throws -> OwnedAssetLease)?
    var onRetentionError: ((Error) -> Void)?
    var onCancelPendingPaste: (() -> Void)?

    struct DispatchRequest {
        let id: UUID
        let occurrenceID: UUID
        let record: ClipboardRecord
        fileprivate let lease: OwnedAssetLease?
    }
    typealias PasteAction = (DispatchRequest, @escaping (PasteCoordinator.Outcome) -> Void) -> Void
    private var pasteActions: [PasteAction] = []
    private var activeDispatch: DispatchRequest?
    private var drainingPasteActions = false
    // Posting Cmd-V does not mean its recipient has read the clipboard. Keep a
    // short handoff window before allowing another Stack write. This is pacing,
    // not a destination acknowledgement or a guarantee for arbitrarily slow apps.
    static let clipboardHandoffInterval: TimeInterval = 0.2
    private let scheduleHandoff: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var handoffID: UUID?
    var pendingPasteCount: Int { pasteActions.count + (activeDispatch == nil ? 0 : 1) }

    init(scheduleHandoff: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    }) {
        self.scheduleHandoff = scheduleHandoff
    }

    private var occurrenceIDs: [UUID] = []
    private var leases: [OwnedAssetLease?] = []
    private var lastConsumed: ConsumedOccurrence?

    private struct ConsumedOccurrence {
        let record: ClipboardRecord
        let occurrenceID: UUID
        let index: Int
        let precedingID: UUID?
        let followingID: UUID?
        let lease: OwnedAssetLease?
    }

    var canRestoreLastConsumed: Bool { isActive && lastConsumed != nil }

    /// Capture this token with `peek()` before dispatch, and pass it back on success.
    /// A stale completion must not consume a different occurrence of the same record.
    var nextOccurrenceID: UUID? {
        guard let index = nextIndex else { return nil }
        return occurrenceIDs[index]
    }

    func activate() {
        guard !isActive else { return }
        sessionID = UUID()
        queue.removeAll()
        occurrenceIDs.removeAll()
        leases.removeAll()
        lastConsumed = nil
        isActive = true
        onChange?()
    }

    /// Ending a session discards its temporary queue and recovery slot.
    func end() {
        guard isActive || !queue.isEmpty || lastConsumed != nil else { return }
        isActive = false
        cancelPendingPastes()
        queue.removeAll()
        occurrenceIDs.removeAll()
        leases.removeAll()
        lastConsumed = nil
        onChange?()
    }

    func append(_ record: ClipboardRecord) {
        guard isActive else { return }
        do { append(record, lease: try retainer?([record])) }
        catch { onRetentionError?(error) }
    }

    /// Capture can pass a lease acquired atomically with the history write.
    func append(_ record: ClipboardRecord, lease: OwnedAssetLease?) {
        guard isActive else { return }
        queue.append(record)
        occurrenceIDs.append(UUID())
        leases.append(lease)
        onChange?()
    }

    /// Persistence may finish after Stack ended or a different session began.
    func appendCaptured(_ record: ClipboardRecord, lease: OwnedAssetLease?, capturedIn session: UUID?) {
        guard isActive, session == sessionID else { return }
        append(record, lease: lease)
    }

    /// Indexes refer to capture order, including when consumption is reversed.
    @discardableResult
    func remove(at index: Int) -> ClipboardRecord? {
        guard isActive, queue.indices.contains(index) else { return nil }
        if occurrenceIDs[index] == activeDispatch?.occurrenceID { cancelPendingPastes() }
        occurrenceIDs.remove(at: index)
        leases.remove(at: index)
        let removed = queue.remove(at: index)
        onChange?()
        return removed
    }

    /// Clear the queue while leaving Stack enabled for subsequent copies.
    func clear() {
        guard isActive else { return }
        // Even an empty visible queue can have captures awaiting persistence.
        sessionID = UUID()
        cancelPendingPastes()
        queue.removeAll()
        occurrenceIDs.removeAll()
        leases.removeAll()
        lastConsumed = nil
        onChange?()
    }

    func peek() -> ClipboardRecord? {
        guard let index = nextIndex else { return nil }
        return queue[index]
    }

    /// One action per physical paste gesture. The caller captures the target for
    /// that gesture; the next occurrence is selected only when its turn begins.
    @discardableResult
    func requestPaste(using action: @escaping PasteAction) -> Bool {
        guard isActive, pendingPasteCount < queue.count else { return false }
        pasteActions.append(action)
        drainPasteActions()
        return true
    }

    func isDispatchCurrent(_ request: DispatchRequest) -> Bool {
        isActive && activeDispatch?.id == request.id && occurrenceIDs.contains(request.occurrenceID)
    }

    /// Suspension cancels pending output, while the queue remains recoverable.
    func cancelPendingPastes() {
        let hadActiveDispatch = activeDispatch != nil
        activeDispatch = nil
        handoffID = nil
        pasteActions.removeAll()
        if hadActiveDispatch { onCancelPendingPaste?() }
    }

    private func drainPasteActions() {
        guard !drainingPasteActions else { return }
        drainingPasteActions = true
        defer { drainingPasteActions = false }
        while activeDispatch == nil, handoffID == nil, !pasteActions.isEmpty {
            guard let index = nextIndex else { pasteActions.removeAll(); return }
            let action = pasteActions.removeFirst()
            let request = DispatchRequest(id: UUID(), occurrenceID: occurrenceIDs[index],
                                          record: queue[index], lease: leases[index])
            activeDispatch = request
            action(request) { [weak self] outcome in self?.finishPaste(request, outcome: outcome) }
        }
    }

    private func finishPaste(_ request: DispatchRequest, outcome: PasteCoordinator.Outcome) {
        guard activeDispatch?.id == request.id else { return }
        activeDispatch = nil
        if outcome == .dispatched {
            // Establish the barrier before markDispatched invokes onChange:
            // a synchronous observer may enqueue another physical gesture.
            let id = UUID()
            handoffID = id
            _ = markDispatched(expectedOccurrenceID: request.occurrenceID)
            guard handoffID == id else { return }
            scheduleHandoff(Self.clipboardHandoffInterval) { [weak self] in
                guard let self, self.handoffID == id else { return }
                self.handoffID = nil
                // The action's target/context predicate is checked by the
                // caller again before writing and by Paste before dispatch.
                self.drainPasteActions()
            }
        } else {
            // Failure must not advance the queue or retry automatically into a
            // later target. A fresh physical gesture can retry the retained item.
            pasteActions.removeAll()
        }
        drainPasteActions()
    }

    /// Call only after the integration confirms dispatch, never on copy-only fallback.
    /// Dispatch is not proof that the target application inserted the content.
    @discardableResult
    func markDispatched(expectedOccurrenceID: UUID? = nil) -> ClipboardRecord? {
        guard isActive,
              let index = expectedOccurrenceID.flatMap({ occurrenceIDs.firstIndex(of: $0) })
                ?? (expectedOccurrenceID == nil ? nextIndex : nil) else { return nil }
        let occurrenceID = occurrenceIDs[index]
        if let expectedOccurrenceID, occurrenceID != expectedOccurrenceID { return nil }
        lastConsumed = ConsumedOccurrence(
            record: queue[index],
            occurrenceID: occurrenceID,
            index: index,
            precedingID: index > 0 ? occurrenceIDs[index - 1] : nil,
            followingID: index + 1 < occurrenceIDs.count ? occurrenceIDs[index + 1] : nil,
            lease: leases[index]
        )
        occurrenceIDs.remove(at: index)
        leases.remove(at: index)
        let record = queue.remove(at: index)
        // Keep an empty session active so its last consumption can still be restored.
        // The key integration must pass ordinary Cmd-V through when peek() is nil.
        onChange?()
        return record
    }

    /// One-level recovery, anchored to surviving neighbors when the queue was edited.
    @discardableResult
    func restoreLastConsumed() -> ClipboardRecord? {
        guard isActive, let consumed = lastConsumed else { return nil }
        let index: Int
        if let followingID = consumed.followingID,
           let followingIndex = occurrenceIDs.firstIndex(of: followingID) {
            index = followingIndex
        } else if let precedingID = consumed.precedingID,
                  let precedingIndex = occurrenceIDs.firstIndex(of: precedingID) {
            index = precedingIndex + 1
        } else {
            index = min(consumed.index, queue.count)
        }
        queue.insert(consumed.record, at: index)
        // A fresh token prevents an old dispatch completion from consuming the restore.
        occurrenceIDs.insert(UUID(), at: index)
        leases.insert(consumed.lease, at: index)
        lastConsumed = nil
        onChange?()
        return consumed.record
    }

    private var nextIndex: Int? {
        guard isActive, !queue.isEmpty else { return nil }
        return direction == .forward ? queue.startIndex : queue.index(before: queue.endIndex)
    }
}
