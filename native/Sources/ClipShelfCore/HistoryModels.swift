import Foundation
import ClipShelfLocalization

public struct Pinboard: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var color: String
    public var sortOrder: Int
    public init(id: UUID = UUID(), name: String, color: String = "#4F7CFF", sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
    }
}

/// A read-only projection; it cannot accidentally overwrite a record with missing binary data.
public struct ClipboardRecordMetadata: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let text: String
    public let sourceApp: String?
    public let sourceBundleID: String?
    public let copiedAt: Date
    public let renamedTitle: String?
    public let ocrText: String?
    public let pinboardID: UUID?
    public let pinboardOrder: Int64?
    public let isInHistory: Bool
    public let revision: Int
    public let kind: ClipboardContentKind
    public let representationTypes: [[String]]
    public let originDeviceID: UUID?
    public let originDeviceName: String?
    public let originDeviceConflict: Bool

    public var title: String {
        if let renamedTitle, !renamedTitle.isEmpty { return renamedTitle }
        let first = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        if first.isEmpty { return kind == .image ? L10n.text("Image") : kind == .file ? L10n.text("Files") : L10n.text("Clipboard item") }
        return String(first.prefix(120))
    }
    public var preview: String { String(text.prefix(1_000)) }
}

public struct ClipboardOriginDevice: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String = "Mac") { self.id = id; self.name = name }
}

public enum HistoryDeviceFilter: Equatable, Sendable { case all, device(UUID), unknown }

/// Explicit navigation within the complete filtered query, independent of its current page.
public enum HistoryPageBoundary: Equatable, Sendable { case first, last }

public struct HistoryMetadataPage: Sendable {
    public let records: [ClipboardRecordMetadata]
    public let offset: Int
    public let hasMore: Bool
    public let focusID: UUID?
}

public enum HistorySortOrder: String, Codable, Sendable { case recent, pinboard }

public struct HistoryQuery: Sendable {
    public var text: String
    public var kind: ClipboardContentKind?
    public var sourceBundleID: String?
    public var copiedAfter: Date?
    public var copiedBefore: Date?
    public var pinboardIDs: Set<UUID>
    public var includePinned: Bool
    public var limit: Int
    public var sortOrder: HistorySortOrder
    public var deviceFilter: HistoryDeviceFilter
    public init(text: String = "", kind: ClipboardContentKind? = nil, sourceBundleID: String? = nil,
                copiedAfter: Date? = nil, copiedBefore: Date? = nil, pinboardIDs: Set<UUID> = [],
                includePinned: Bool = true, limit: Int = 500, sortOrder: HistorySortOrder = .recent,
                deviceFilter: HistoryDeviceFilter = .all) {
        self.text = text
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.copiedAfter = copiedAfter
        self.copiedBefore = copiedBefore
        self.pinboardIDs = pinboardIDs
        self.includePinned = includePinned
        self.limit = limit
        self.sortOrder = sortOrder
        self.deviceFilter = deviceFilter
    }
}

public enum BackupRestoreMode: Sendable { case merge, replace }

public struct BackupRestoreSummary: Sendable {
    public let importedRecords: Int
    public let importedPinboards: Int
    public let recoveryBackupURL: URL
    public let restoredAsLocalOnly: Bool
    public let identitiesRemapped: Bool
}

struct HistoryBackup: Codable, Sendable {
    var schemaVersion = 3
    var records: [ClipboardRecord]
    var pinboards: [Pinboard]
    var pinboardOrder: [UUID]? = nil
    var containsSyncedContent: Bool? = nil
    var ownedFiles: [OwnedFileBackupAsset]? = nil
    var ownedFileBindings: [OwnedFileBinding]? = nil
}

struct BackupEnvelope: Codable {
    var formatVersion = 1
    var checksum: String
    var payload: Data
}
