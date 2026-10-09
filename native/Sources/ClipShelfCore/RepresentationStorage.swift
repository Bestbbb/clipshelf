import CryptoKit
import Foundation

struct StoredRepresentation: Codable {
    var typeIdentifier: String
    var digest: String
    var byteCount: Int
}

struct RepresentationStorage {
    let directory: URL
    let spaceCoordinator: StorageSpaceCoordinator?
    static let maximumRepresentationBytes = 64 * 1_024 * 1_024

    init(databaseURL: URL, spaceCoordinator: StorageSpaceCoordinator? = nil) throws {
        self.spaceCoordinator = spaceCoordinator
        directory = databaseURL.deletingPathExtension().appendingPathExtension("attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func encode(_ parts: [ClipboardPart], budget: HistoryWriteBudget? = nil) throws -> Data {
        let stored: [[StoredRepresentation]] = try parts.map { part in
            try part.representations.map { representation in
                guard !representation.typeIdentifier.isEmpty,
                      representation.data.count <= Self.maximumRepresentationBytes else {
                    throw HistoryStoreError.valueTooLarge
                }
                let digest = Self.digest(representation.data)
                let file = try url(for: digest)
                if FileManager.default.fileExists(atPath: file.path) {
                    let existing = try Data(contentsOf: file, options: .mappedIfSafe)
                    guard existing.count == representation.data.count, Self.digest(existing) == digest else {
                        throw HistoryStoreError.corruptAttachment
                    }
                } else {
                    let lease = try budget?.isPrepaid == true ? nil : spaceCoordinator?.reserve([
                        .init(destination: file, bytes: Int64(representation.data.count))
                    ])
                    defer { try? lease?.release() }
                    try lease?.revalidate()
                    try representation.data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    try lease?.validateDestinations()
                }
                return StoredRepresentation(typeIdentifier: representation.typeIdentifier,
                                            digest: digest, byteCount: representation.data.count)
            }
        }
        return try JSONEncoder().encode(stored)
    }

    func decode(_ metadata: Data?) throws -> [ClipboardPart] {
        guard let metadata else { return [] }
        let stored = try JSONDecoder().decode([[StoredRepresentation]].self, from: metadata)
        return try stored.map { representations in
            ClipboardPart(representations: try representations.map { representation in
                guard representation.byteCount >= 0,
                      representation.byteCount <= Self.maximumRepresentationBytes else {
                    throw HistoryStoreError.corruptAttachment
                }
                let file = try url(for: representation.digest)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attributes[.size] as? NSNumber, size.int64Value == Int64(representation.byteCount) else {
                    throw HistoryStoreError.corruptAttachment
                }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count == representation.byteCount, Self.digest(data) == representation.digest else {
                    throw HistoryStoreError.corruptAttachment
                }
                return ClipboardRepresentation(typeIdentifier: representation.typeIdentifier, data: data)
            })
        }
    }

    func url(for digest: String) throws -> URL {
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw HistoryStoreError.corruptAttachment
        }
        return directory.appendingPathComponent(digest + ".blob", isDirectory: false)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
