import Foundation

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
    public let isInHistory: Bool
    public let revision: Int
    public let kind: ClipboardContentKind
    public let representationTypes: [[String]]

    public var title: String {
        if let renamedTitle, !renamedTitle.isEmpty { return renamedTitle }
        let first = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        if first.isEmpty { return kind == .image ? "Image" : kind == .file ? "Files" : "Clipboard item" }
        return String(first.prefix(120))
    }
    public var preview: String { String(text.prefix(1_000)) }
}

public struct HistoryQuery: Sendable {
    public var text: String
    public var kind: ClipboardContentKind?
    public var sourceBundleID: String?
    public var copiedAfter: Date?
    public var copiedBefore: Date?
    public var pinboardIDs: Set<UUID>
    public var includePinned: Bool
    public var limit: Int
    public init(text: String = "", kind: ClipboardContentKind? = nil, sourceBundleID: String? = nil,
                copiedAfter: Date? = nil, copiedBefore: Date? = nil, pinboardIDs: Set<UUID> = [],
                includePinned: Bool = true, limit: Int = 500) {
        self.text = text
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.copiedAfter = copiedAfter
        self.copiedBefore = copiedBefore
        self.pinboardIDs = pinboardIDs
        self.includePinned = includePinned
        self.limit = limit
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

struct HistoryBackup: Codable {
    var schemaVersion = 2
    var records: [ClipboardRecord]
    var pinboards: [Pinboard]
    var pinboardOrder: [UUID]? = nil
    var containsSyncedContent: Bool? = nil
}

struct BackupEnvelope: Codable {
    var formatVersion = 1
    var checksum: String
    var payload: Data
}
