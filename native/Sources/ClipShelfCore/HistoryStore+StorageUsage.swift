import Foundation

extension HistoryStore {
    /// Captures immutable paths only. Scanning this scope must run on a background worker and
    /// never takes the SQLite connection lock. External clipboard file URLs are not included.
    public func storageUsageScope(additionalRoots: [StorageUsageRoot] = []) -> StorageUsageScope {
        // Owned storage established a canonical profile parent at store initialization.
        let profile = ownedFileStorage.directory.deletingLastPathComponent().deletingLastPathComponent()
        return StorageUsageScope(profileDirectory: profile, databaseName: databaseURL.lastPathComponent,
                                 additionalRoots: additionalRoots)
    }
}
