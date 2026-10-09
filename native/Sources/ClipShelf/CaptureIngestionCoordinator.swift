import Foundation

/// Serial ingestion with bounded retained inputs, explicit retry, and generation-safe receipts.
@MainActor
final class CaptureIngestionCoordinator<Input: Sendable, Output: Sendable> {
    private struct Entry {
        let id = UUID()
        let input: Input
        let byteCount: Int
    }
    private struct Active {
        let entry: Entry
        let generation: UUID
    }

    private let maxPendingCount: Int
    private let maxPendingBytes: Int
    private let process: @Sendable (Input) async throws -> Output
    private var entries: [Entry] = []
    private var queuedBytes = 0
    private var generation = UUID()
    private var active: Active?
    private var task: Task<Void, Never>?
    private var settling = false
    private var failedEntryID: UUID?

    var onSaved: ((Input, Output) -> Void)?
    var onFailure: ((Input, Error) -> Void)?
    /// Even an invalidated write may have committed; callers may reload without showing old status.
    var onSettled: (() -> Void)?
    var onStateChanged: (() -> Void)?

    var isProcessing: Bool { active != nil }
    var hasFailure: Bool { failedEntryID != nil }
    var pendingCount: Int { entries.count + (retiredActive == nil ? 0 : 1) }
    var pendingBytes: Int { queuedBytes + (retiredActive?.entry.byteCount ?? 0) }
    /// Includes failed inputs and an invalidated write until its worker actually settles.
    func containsPending(where predicate: (Input) -> Bool) -> Bool {
        if entries.contains(where: { predicate($0.input) }) { return true }
        return retiredActive.map { predicate($0.entry.input) } ?? false
    }
    private var retiredActive: Active? {
        guard let active, active.generation != generation else { return nil }
        return active
    }

    init(maxPendingCount: Int = 32, maxPendingBytes: Int = 128 * 1_024 * 1_024,
         process: @escaping @Sendable (Input) async throws -> Output) {
        self.maxPendingCount = max(0, maxPendingCount)
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.process = process
    }

    @discardableResult
    func enqueue(_ input: Input, byteCount: Int) -> Bool {
        guard byteCount >= 0, pendingCount < maxPendingCount,
              byteCount <= maxPendingBytes - pendingBytes else { return false }
        entries.append(Entry(input: input, byteCount: byteCount))
        queuedBytes += byteCount
        onStateChanged?()
        startNextIfPossible()
        return true
    }

    func retry() {
        guard failedEntryID != nil else { return }
        failedEntryID = nil
        onStateChanged?()
        startNextIfPossible()
    }

    /// Cancellation cannot undo a backend write already in progress. Keep its slot and
    /// budget until it settles, while removing all queued inputs and rejecting its receipt.
    func discardPending() {
        generation = UUID()
        entries.removeAll()
        queuedBytes = 0
        failedEntryID = nil
        task?.cancel()
        onStateChanged?()
    }

    private func startNextIfPossible() {
        guard active == nil, !settling, failedEntryID == nil, let entry = entries.first else { return }
        let started = Active(entry: entry, generation: generation)
        active = started
        let process = process
        task = Task { @MainActor [weak self] in
            let result: Result<Output, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await process(entry.input))
            } catch { result = .failure(error) }
            self?.finish(started, result: result)
        }
        onStateChanged?()
    }

    private func finish(_ started: Active, result: Result<Output, Error>) {
        guard active?.entry.id == started.entry.id else { return }
        active = nil
        task = nil
        settling = true
        defer { settling = false; startNextIfPossible() }
        if generation == started.generation, entries.first?.id == started.entry.id {
            switch result {
            case .success(let output):
                entries.removeFirst()
                queuedBytes -= started.entry.byteCount
                onSaved?(started.entry.input, output)
            case .failure(let error):
                failedEntryID = started.entry.id
                onFailure?(started.entry.input, error)
            }
        }
        onSettled?()
        onStateChanged?()
    }
}
