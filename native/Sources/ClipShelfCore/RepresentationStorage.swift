import CryptoKit
import Darwin
import Foundation

struct StoredRepresentation: Codable {
    var typeIdentifier: String
    var digest: String
    var byteCount: Int
}

/// Created by this transaction, never an existing deduplicated file. Cleanup uses the
/// pinned directory/file identities and runs before releasing the SQLite writer lock.
struct NewRepresentationFile {
    let directory: URL
    let directoryIdentity: StorageSpaceNode
    let name: String
    let identity: StorageSpaceNode

    func removeIfUnchanged() {
        guard let descriptor = try? StorageSpaceFiles.openDirectory(directory) else { return }
        defer { Darwin.close(descriptor) }
        guard let info = try? StorageSpaceFiles.info(descriptor), StorageSpaceNode(info) == directoryIdentity else { return }
        var value = stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_uid == geteuid(),
              StorageSpaceNode(value) == identity else { return }
        _ = unlinkat(descriptor, name, 0)
    }
}

/// One descriptor per transaction, including arbitrarily many representations. Databases
/// with different extensions can share an attachment directory, so the SQLite lock alone
/// does not protect a newly created digest from being adopted before its creator commits.
final class RepresentationWriteSession {
    let directory: URL
    let descriptor: Int32
    let identity: StorageSpaceNode
    init(directory: URL) throws {
        self.directory = try StorageSpaceFiles.canonicalDirectory(directory)
        let descriptor = try StorageSpaceFiles.openDirectory(self.directory)
        do {
            try StorageSpaceFiles.lock(descriptor)
            identity = StorageSpaceNode(try StorageSpaceFiles.info(descriptor))
            self.descriptor = descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
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

    func beginWriteSession() throws -> RepresentationWriteSession { try RepresentationWriteSession(directory: directory) }

    func encode(_ parts: [ClipboardPart], budget: HistoryWriteBudget? = nil,
                session: RepresentationWriteSession? = nil,
                didCreate: ((NewRepresentationFile) -> Void)? = nil) throws -> Data {
        let session = try session ?? beginWriteSession()
        defer { withExtendedLifetime(session) {} }
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
                    try publishNew(representation.data, digest: digest, session: session, didCreate: didCreate)
                    try lease?.validateDestinations()
                }
                return StoredRepresentation(typeIdentifier: representation.typeIdentifier,
                                            digest: digest, byteCount: representation.data.count)
            }
        }
        return try JSONEncoder().encode(stored)
    }

    /// Publish without replacing a concurrent creator's digest. The random staging name
    /// exists only during this call; a failed transaction may remove only its own inode.
    private func publishNew(_ data: Data, digest: String, session: RepresentationWriteSession,
                            didCreate: ((NewRepresentationFile) -> Void)?) throws {
        let canonical = try StorageSpaceFiles.canonicalDirectory(directory)
        let directoryFD = try StorageSpaceFiles.openDirectory(canonical)
        defer { Darwin.close(directoryFD) }
        let directoryIdentity = StorageSpaceNode(try StorageSpaceFiles.info(directoryFD))
        guard directoryIdentity == session.identity else { throw HistoryStoreError.corruptAttachment }
        let staging = ".representation-" + UUID().uuidString
        let descriptor = openat(directoryFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageSpaceFiles.posixFailure() }
        defer { Darwin.close(descriptor); _ = unlinkat(directoryFD, staging, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StorageSpaceFiles.posixFailure() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw StorageSpaceFiles.posixFailure() }
        let identity = StorageSpaceNode(try StorageSpaceFiles.info(descriptor))
        let name = digest + ".blob"
        if linkat(directoryFD, staging, directoryFD, name, 0) != 0 {
            guard errno == EEXIST else { throw StorageSpaceFiles.posixFailure() }
            let existing = try Data(contentsOf: canonical.appendingPathComponent(name), options: .mappedIfSafe)
            guard existing == data else { throw HistoryStoreError.corruptAttachment }
            return
        }
        let created = NewRepresentationFile(directory: canonical, directoryIdentity: directoryIdentity, name: name, identity: identity)
        guard unlinkat(directoryFD, staging, 0) == 0 else {
            // Both names are our inode. Remove the final name while the staging cleanup owns
            // the other link; do not leave a newly published blob after a failed encode.
            if StorageSpaceFiles.matches(identity, name: name, directory: directoryFD) { _ = unlinkat(directoryFD, name, 0) }
            throw StorageSpaceFiles.posixFailure()
        }
        do {
            guard fsync(directoryFD) == 0 else { throw StorageSpaceFiles.posixFailure() }
            didCreate?(created)
        } catch { created.removeIfUnchanged(); throw error }
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
