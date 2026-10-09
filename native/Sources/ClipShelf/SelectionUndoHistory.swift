import ClipShelfCore
import Foundation

enum SelectionUndoAction: Sendable {
    case move(HistorySelectionMoveUndo)
    case deletion([ClipboardRecord], HistorySelectionDeleteUndo)
    case edit(HistorySelectionEditUndo)
}

final class SelectionUndoTicket: NSObject {
    let id = UUID()
    var action: SelectionUndoAction
    let payloadBytes: Int

    init(action: SelectionUndoAction) {
        self.action = action
        if case .deletion(let records, _) = action { payloadBytes = Self.payloadSize(records) }
        else if case .edit(let token) = action { payloadBytes = Self.payloadSize([token.original]) }
        else { payloadBytes = 0 }
    }

    static func payloadSize(_ records: [ClipboardRecord]) -> Int {
        var total = 0
        func add(_ count: Int) {
            let (sum, overflow) = total.addingReportingOverflow(count)
            total = overflow ? Int.max : sum
        }
        for record in records {
            add(record.text.utf8.count); add(record.rtf?.count ?? 0); add(record.html?.count ?? 0)
            for part in record.parts { for representation in part.representations { add(representation.data.count) } }
        }
        return total
    }
}

private final class WeakSelectionUndoTicket {
    weak var value: SelectionUndoTicket?
    init(_ value: SelectionUndoTicket) { self.value = value }
}

/// The manager's action owns its ticket, so automatic eviction also releases its payload.
@MainActor final class SelectionUndoHistory {
    let manager: UndoManager
    let maximumPayloadBytes: Int
    private let maximumActions: Int
    private var entries: [WeakSelectionUndoTicket] = []
    var tickets: [SelectionUndoTicket] { entries.compactMap(\.value) }
    var retainedPayloadBytes: Int { tickets.reduce(0) { $0 + $1.payloadBytes } }

    init(manager: UndoManager, maximumActions: Int = 10, maximumPayloadBytes: Int = 512 * 1_024 * 1_024) {
        precondition(maximumActions > 0 && maximumPayloadBytes >= 0)
        self.manager = manager
        self.maximumActions = maximumActions
        self.maximumPayloadBytes = maximumPayloadBytes
        manager.levelsOfUndo = maximumActions
        manager.groupsByEvent = false
    }

    @discardableResult
    func register(_ action: SelectionUndoAction, handler: @escaping @MainActor (SelectionUndoTicket) -> Void) -> Bool {
        let ticket = SelectionUndoTicket(action: action)
        guard ticket.payloadBytes <= maximumPayloadBytes else { return false }
        while let oldest = tickets.first,
              tickets.count >= maximumActions || retainedPayloadBytes > maximumPayloadBytes - ticket.payloadBytes {
            remove(oldest)
        }
        entries.removeAll { $0.value == nil }
        entries.append(WeakSelectionUndoTicket(ticket))
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: ticket) { [ticket] _ in
            MainActor.assumeIsolated { handler(ticket) }
        }
        manager.setActionName({
            switch action {
            case .move: return "移动所选内容"
            case .deletion: return "删除所选内容"
            case .edit: return "编辑内容"
            }
        }())
        manager.endUndoGrouping()
        return true
    }

    func remove(_ ticket: SelectionUndoTicket) {
        manager.removeAllActions(withTarget: ticket)
        entries.removeAll { $0.value == nil || $0.value === ticket }
    }

    /// Retire whole atomic actions that depend on any cleaned-up record. Each
    /// ticket is its own UndoManager target; unrelated groups stay in order.
    @discardableResult
    func invalidate(recordIDs: Set<UUID>) -> Int {
        guard !recordIDs.isEmpty else { return 0 }
        var removed = 0
        for ticket in tickets {
            let intersects: Bool
            switch ticket.action {
            case .move(let undo):
                intersects = !undo.affectedRecordIDs.isDisjoint(with: recordIDs)
            case .deletion(let originals, _):
                intersects = originals.contains { recordIDs.contains($0.id) }
            case .edit(let undo):
                intersects = recordIDs.contains(undo.original.id)
            }
            if intersects { remove(ticket); removed += 1 }
        }
        return removed
    }

    func removeAll() {
        manager.removeAllActions()
        entries.removeAll()
    }

    /// The database undo has already committed. Invalid earlier tickets are discarded separately.
    @discardableResult
    func rebaseActions(using store: HistoryStore, receipt: HistorySelectionUndoReceipt) -> Int {
        var invalidated = 0
        for ticket in Array(tickets) {
            do {
                switch ticket.action {
                case .move(let undo): ticket.action = .move(try store.rebaseSelectionMoveUndo(undo, after: receipt))
                case .edit(let undo): ticket.action = .edit(try store.rebaseSelectionEditUndo(undo, after: receipt))
                case .deletion: continue
                }
            }
            catch { remove(ticket); invalidated += 1 }
        }
        return invalidated
    }
}
