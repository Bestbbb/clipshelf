import CSQLite
import Foundation

/// Cancels one read request without interrupting other operations on the store's connection.
/// A token is single-use: cancellation is permanent, so each new request needs its own token.
public final class HistoryReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}

extension HistoryStore {
    /// Call only while holding the connection lock, around read-only statements. The callback
    /// is removed before this helper returns or throws, including before caller cleanup SQL.
    func withReadCancellation<T>(_ cancellation: HistoryReadCancellation?, _ operation: () throws -> T) throws -> T {
        guard let cancellation else { return try operation() }
        try cancellation.checkCancellation()
        let context = Unmanaged.passRetained(cancellation)
        sqlite3_progress_handler(database, 1_000, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<HistoryReadCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
        }, context.toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            context.release()
        }
        do {
            let result = try operation()
            try cancellation.checkCancellation()
            return result
        } catch {
            if cancellation.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
