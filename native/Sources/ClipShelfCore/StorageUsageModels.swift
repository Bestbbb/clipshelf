import Foundation

public enum StorageUsageCategory: String, CaseIterable, Sendable {
    case database, representations, ownedOriginals, ownedOpenCopies, ownedQuarantine, ownedCredentials
    case backups, shareImports, ocrCache, imageExports, shareInbox, storageCredentials, directoryMetadata, unknown
}

public enum StorageUsageScopeKind: String, Sendable { case profile, sharedCache, appGroup }
public enum StorageUsageUnavailableReason: String, Sendable { case notConfigured, notAuthorized, unavailable }

/// An explicitly authorized directory. A nil URL describes unavailable scope, never an empty directory.
public struct StorageUsageRoot: Sendable {
    public let id: String
    public let url: URL?
    public let category: StorageUsageCategory
    public let scopeKind: StorageUsageScopeKind
    public let optional: Bool
    public let unavailability: StorageUsageUnavailableReason?

    public init(id: String, url: URL, category: StorageUsageCategory,
                scopeKind: StorageUsageScopeKind, optional: Bool = true) {
        // Foundation standardization can rewrite /private/var to its /var symlink alias.
        // Keep the authorized spelling: the scanner validates every component without following links.
        self.id = id; self.url = url; self.category = category
        self.scopeKind = scopeKind; self.optional = optional; unavailability = nil
    }
    public static func unavailable(id: String, category: StorageUsageCategory,
                                   scopeKind: StorageUsageScopeKind, reason: StorageUsageUnavailableReason) -> Self {
        Self(id: id, category: category, scopeKind: scopeKind, reason: reason)
    }
    private init(id: String, category: StorageUsageCategory, scopeKind: StorageUsageScopeKind,
                 reason: StorageUsageUnavailableReason) {
        self.id = id; url = nil; self.category = category; self.scopeKind = scopeKind
        optional = false; unavailability = reason
    }
}

public struct StorageUsageScope: Sendable {
    public let profileDirectory: URL
    public let databaseName: String
    public let roots: [StorageUsageRoot]
    /// The profile path should be canonical. Symbolic links, including aliases in root paths,
    /// are rejected by the scanner rather than granting access to another tree.
    public init(profileDirectory: URL, databaseName: String, additionalRoots: [StorageUsageRoot] = []) {
        self.profileDirectory = profileDirectory; self.databaseName = databaseName
        roots = [StorageUsageRoot(id: "profile", url: profileDirectory, category: .unknown,
                                  scopeKind: .profile, optional: false)] + additionalRoots
    }
}

public struct StorageUsageLimits: Sendable {
    public let maximumEntries: Int
    public let maximumDepth: Int
    public let maximumDuration: TimeInterval
    public let maximumIssues: Int
    public init(maximumEntries: Int = 200_000, maximumDepth: Int = 48,
                maximumDuration: TimeInterval = 30, maximumIssues: Int = 200) {
        self.maximumEntries = max(0, maximumEntries); self.maximumDepth = max(0, maximumDepth)
        self.maximumDuration = maximumDuration.isFinite ? max(0, maximumDuration) : 30
        self.maximumIssues = max(1, maximumIssues)
    }
}

public enum StorageUsageIssueReason: String, Sendable {
    case unavailableRoot, invalidRoot, overlappingScope, symbolicLink, unreadable, changedDuringScan
    case unknownLayout, unsupportedFileType, invalidMetadata, entryLimit, depthLimit, timeLimit
}
public struct StorageUsageIssue: Sendable {
    public let rootID: String
    public let relativePath: String
    public let reason: StorageUsageIssueReason
    public let errorCode: Int32?
}
public enum StorageUsageRootStatus: String, Sendable { case measured, notPresent, unavailable, partial }
public struct StorageUsageRootResult: Sendable {
    public let root: StorageUsageRoot
    public let status: StorageUsageRootStatus
    public let volumeID: String?
}

public struct StorageUsageMeasurement: Sendable {
    public let category: StorageUsageCategory
    public let scopeKind: StorageUsageScopeKind
    public let volumeID: String
    /// Sum of regular-file lengths. Directory metadata is excluded from logical bytes.
    public var logicalBytes: Int64
    /// st_blocks * 512 for regular files and directories; APFS clone sharing is not resolved.
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var directoryCount: Int
    public var deduplicatedFileCount: Int
    public var skippedEntryCount: Int
}

/// An observed interval, not an atomic filesystem snapshot or an estimate of reclaimable capacity.
/// Roots are visited by ID, then URL; entries use lexical name order. The first (device,inode)
/// owns the measured bytes across all categories/scopes. Child roots are excluded from parent roots.
public struct StorageUsageReport: Sendable {
    public let scope: StorageUsageScope
    public let startedAt: Date
    public let finishedAt: Date
    public let roots: [StorageUsageRootResult]
    public let measurements: [StorageUsageMeasurement]
    public let issues: [StorageUsageIssue]
    public let omittedIssueCount: Int
    public let examinedEntryCount: Int
    public var isPartial: Bool { !issues.isEmpty || omittedIssueCount > 0 }
    public var logicalBytes: Int64 { measurements.reduce(0) { $0 + $1.logicalBytes } }
    public var allocatedBytes: Int64 { measurements.reduce(0) { $0 + $1.allocatedBytes } }
}
