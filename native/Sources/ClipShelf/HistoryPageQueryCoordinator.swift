import Foundation
import ClipShelfCore

/// Serializes database work while replacing queued searches with the newest request.
/// Cancellation retains the active slot until the reader has actually returned.
@MainActor
final class HistoryPageQueryCoordinator<Value: Sendable> {
    typealias Read = @Sendable (HistoryReadCancellation) throws -> Value
    private struct Request {
        let id = UUID()
        let read: Read
        let completion: (Result<Value, Error>) -> Void
    }
    private struct Active {
        let request: Request
        let cancellation: HistoryReadCancellation
        let task: Task<Void, Never>
    }
    private var active: Active?
    private var pending: Request?
    private var latestID: UUID?

    func submit(read: @escaping Read, completion: @escaping (Result<Value, Error>) -> Void) {
        let request = Request(read: read, completion: completion)
        latestID = request.id
        pending = request
        active?.cancellation.cancel()
        active?.task.cancel()
        startNextIfIdle()
    }

    func cancel() {
        latestID = nil
        pending = nil
        active?.cancellation.cancel()
        active?.task.cancel()
    }

    private func startNextIfIdle() {
        guard active == nil, let request = pending else { return }
        pending = nil
        let cancellation = HistoryReadCancellation()
        let id = request.id, read = request.read
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> Void in
            let result = Result {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                let value = try read(cancellation)
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                return value
            }
            await self?.finished(id: id, result: result)
        }
        active = Active(request: request, cancellation: cancellation, task: task)
    }

    private func finished(id: UUID, result: Result<Value, Error>) {
        guard let finished = active, finished.request.id == id else { return }
        active = nil
        if latestID == id, !finished.cancellation.isCancelled {
            latestID = nil
            // Clear the active slot before calling back: a completion may submit or cancel.
            finished.request.completion(result)
        }
        startNextIfIdle()
    }

    deinit {
        active?.cancellation.cancel()
        active?.task.cancel()
    }
}

struct HistoryPanelReadResult: Sendable {
    let page: HistoryMetadataPage
    let pinboards: [Pinboard]
    let sources: [String: String]
    let devices: [ClipboardOriginDevice]
    let localDeviceID: UUID
}
