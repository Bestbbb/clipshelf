import Foundation

extension HistoryStore {
    /// The caller has displayed this exact set and confirmed that external consumers
    /// no longer need it. Current clipboard publications and live leases remain protected.
    public func clearConfirmedExternalOwnedPublications(expectedIDs: Set<UUID>) throws {
        try synchronized {
            try ownedRetentionTransaction {
                let filter = "purpose IN ('legacyExternal','externalOpen','sharing','drag')"
                let current = try ownedUUIDSet("SELECT id FROM owned_asset_publications WHERE " + filter)
                guard current == expectedIDs else { throw OwnedStorageError.changed }
                try execute("DELETE FROM owned_asset_publications WHERE " + filter)
            }
        }
    }
}
