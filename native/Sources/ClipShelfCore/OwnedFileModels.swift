import Foundation

/// Explicit incoming bytes. A file URL alone never grants local ownership.
public struct OwnedFileImport: Sendable {
    public let partIndex: Int
    public let representationIndex: Int
    public let filename: String
    public let data: Data
    public init(partIndex: Int, representationIndex: Int, filename: String, data: Data) {
        self.partIndex = partIndex; self.representationIndex = representationIndex
        self.filename = filename; self.data = data
    }
}

public struct OwnedFileAsset: Codable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let byteCount: Int
    public let sha256: String
    public init(id: UUID, filename: String, byteCount: Int, sha256: String) {
        self.id = id; self.filename = filename; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public struct OwnedFileBinding: Codable, Equatable, Sendable {
    public let recordID: UUID
    public let partIndex: Int
    public let representationIndex: Int
    public let assetID: UUID
    public init(recordID: UUID, partIndex: Int, representationIndex: Int, assetID: UUID) {
        self.recordID = recordID; self.partIndex = partIndex
        self.representationIndex = representationIndex; self.assetID = assetID
    }
}

public struct OwnedFileBackupAsset: Codable, Equatable, Sendable {
    public let asset: OwnedFileAsset
    public let data: Data
    public init(asset: OwnedFileAsset, data: Data) { self.asset = asset; self.data = data }
}
