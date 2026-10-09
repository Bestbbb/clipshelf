import ClipShelfCore
import Foundation

struct CapturePersistenceInput: Sendable {
    let snapshot: ClipboardCaptureSnapshot
    let stackSessionID: UUID?

    /// Frozen file references may point to managed files. Delay reclamation without
    /// resolving paths or requiring database access while persistence is failing.
    var blocksOwnedReclamation: Bool {
        snapshot.parts.contains { part in
            part.representations.contains { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }
        }
    }
}

enum CapturePersistence {
    /// Only frozen bytes cross this boundary. Pasteboard and UI objects stay on MainActor.
    static func save(_ input: CapturePersistenceInput, to store: HistoryStore) async throws -> RetainedClipboardRecords {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let record = try ClipboardCodec.record(from: input.snapshot)
            try Task.checkCancellation()
            // Once the transaction begins, cancellation cannot undo a committed record.
            return try store.recordRetainingCapturedOwnedFiles(record, purpose: .stack)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: { worker.cancel() })
    }
}
