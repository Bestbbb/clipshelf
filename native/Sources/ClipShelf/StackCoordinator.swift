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
    var direction: Direction = .forward {
        didSet {
            if oldValue != direction { onChange?() }
        }
    }
    var onChange: (() -> Void)?

    private var occurrenceIDs: [UUID] = []
    private var lastConsumed: ConsumedOccurrence?

    private struct ConsumedOccurrence {
        let record: ClipboardRecord
        let occurrenceID: UUID
        let index: Int
        let precedingID: UUID?
        let followingID: UUID?
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
        queue.removeAll()
        occurrenceIDs.removeAll()
        lastConsumed = nil
        isActive = true
        onChange?()
    }

    /// Ending a session discards its temporary queue and recovery slot.
    func end() {
        guard isActive || !queue.isEmpty || lastConsumed != nil else { return }
        isActive = false
        queue.removeAll()
        occurrenceIDs.removeAll()
        lastConsumed = nil
        onChange?()
    }

    func append(_ record: ClipboardRecord) {
        guard isActive else { return }
        queue.append(record)
        occurrenceIDs.append(UUID())
        onChange?()
    }

    /// Indexes refer to capture order, including when consumption is reversed.
    @discardableResult
    func remove(at index: Int) -> ClipboardRecord? {
        guard isActive, queue.indices.contains(index) else { return nil }
        occurrenceIDs.remove(at: index)
        let removed = queue.remove(at: index)
        onChange?()
        return removed
    }

    /// Clear the queue while leaving Stack enabled for subsequent copies.
    func clear() {
        guard !queue.isEmpty || lastConsumed != nil else { return }
        queue.removeAll()
        occurrenceIDs.removeAll()
        lastConsumed = nil
        onChange?()
    }

    func peek() -> ClipboardRecord? {
        guard let index = nextIndex else { return nil }
        return queue[index]
    }

    /// Call only after the integration confirms dispatch, never on copy-only fallback.
    /// Dispatch is not proof that the target application inserted the content.
    @discardableResult
    func markDispatched(expectedOccurrenceID: UUID? = nil) -> ClipboardRecord? {
        guard let index = nextIndex else { return nil }
        let occurrenceID = occurrenceIDs[index]
        if let expectedOccurrenceID, occurrenceID != expectedOccurrenceID { return nil }
        lastConsumed = ConsumedOccurrence(
            record: queue[index],
            occurrenceID: occurrenceID,
            index: index,
            precedingID: index > 0 ? occurrenceIDs[index - 1] : nil,
            followingID: index + 1 < occurrenceIDs.count ? occurrenceIDs[index + 1] : nil
        )
        occurrenceIDs.remove(at: index)
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
        lastConsumed = nil
        onChange?()
        return consumed.record
    }

    private var nextIndex: Int? {
        guard isActive, !queue.isEmpty else { return nil }
        return direction == .forward ? queue.startIndex : queue.index(before: queue.endIndex)
    }
}
