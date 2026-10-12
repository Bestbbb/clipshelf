import Foundation

/// Session-only metadata; no payloads, window titles, input text or file paths.
@MainActor
final class PasteOutcomeLog {
    struct Entry {
        let timestamp: Date
        let bundleID: String?
        let mode: PasteStrictness
        let outcome: PasteCoordinator.Outcome
        let failure: ValidationTrace.Failure?
        let method: PasteDispatch.Method?
        let elapsedMS: Double
    }
    private(set) var entries: [Entry] = []
    func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > 20 { entries.removeFirst(entries.count - 20) }
    }
}
