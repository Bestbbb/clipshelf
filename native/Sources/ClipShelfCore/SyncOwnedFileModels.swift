import Foundation
import Darwin

public struct SyncOwnedFileDescriptor: Codable, Equatable, Hashable, Sendable {
    public let digest: String
    public let byteCount: Int
    public let filename: String
    public init(digest: String, byteCount: Int, filename: String) { self.digest = digest; self.byteCount = byteCount; self.filename = filename }
    public func validate() throws {
        try OwnedFileStorage.validateFilename(filename)
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }), (0...SyncOwnedFileLimits.maximumFileBytes).contains(byteCount) else { throw SyncError.invalidOperation }
    }
}
public struct SyncOwnedFileBinding: Codable, Equatable, Sendable {
    public let partIndex: Int
    public let representationIndex: Int
    public let digest: String
    public let filename: String
    public init(partIndex: Int, representationIndex: Int, digest: String, filename: String) { self.partIndex = partIndex; self.representationIndex = representationIndex; self.digest = digest; self.filename = filename }
}
public enum SyncOwnedFileLimits {
    public static let maximumFileBytes = 64 * 1_024 * 1_024
    public static let maximumOperationBytes = 256 * 1_024 * 1_024
    public static let maximumFilesPerOperation = 64
    public static let maximumPassBytes = 512 * 1_024 * 1_024
}
public struct SyncOwnedFileManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let files: [SyncOwnedFileDescriptor]
    public let bindings: [SyncOwnedFileBinding]
    public init(version: Int = 1, files: [SyncOwnedFileDescriptor], bindings: [SyncOwnedFileBinding]) { self.version = version; self.files = files; self.bindings = bindings }
    public static func token(digest: String, filename: String) -> String {
        "clipshelf-owned://" + digest + "/" + Data(filename.utf8).base64EncodedString()
    }
    public func validate(record: ClipboardRecord) throws {
        guard version == 1, !files.isEmpty, files.count <= SyncOwnedFileLimits.maximumFilesPerOperation,
              !bindings.isEmpty, bindings.count <= SyncOwnedFileLimits.maximumFilesPerOperation else { throw SyncError.invalidOperation }
        var keys = Set<String>(), digests: [String: Int] = [:], total = 0
        for file in files {
            try file.validate()
            guard keys.insert(file.digest + ":" + file.filename).inserted,
                  file.byteCount <= SyncOwnedFileLimits.maximumOperationBytes - total else { throw SyncError.invalidOperation }
            if let length = digests[file.digest], length != file.byteCount { throw SyncError.invalidOperation }
            digests[file.digest] = file.byteCount; total += file.byteCount
        }
        var parts = Set<Int>(), used = Set<String>()
        for binding in bindings {
            let key = binding.digest + ":" + binding.filename
            guard keys.contains(key), parts.insert(binding.partIndex).inserted,
                  record.parts.indices.contains(binding.partIndex), binding.representationIndex == 0,
                  record.parts[binding.partIndex].representations.count == 1 else { throw SyncError.invalidOperation }
            let rep = record.parts[binding.partIndex].representations[0]
            guard rep.typeIdentifier == "public.file-url", rep.data == Data(Self.token(digest: binding.digest, filename: binding.filename).utf8) else { throw SyncError.invalidOperation }
            used.insert(key)
        }
        guard used == keys else { throw SyncError.invalidOperation }
    }
}
public enum SyncOwnedFileDatabase: String, Codable, Sendable { case privateDatabase, sharedDatabase }
public struct SyncOwnedFileScope: Codable, Equatable, Sendable {
    public let accountID: String
    public let containerIdentifier: String
    public let database: SyncOwnedFileDatabase
    public let zoneOwnerName: String
    public let zoneName: String
    public let namespace: String
    public init(accountID: String, containerIdentifier: String, database: SyncOwnedFileDatabase, zoneOwnerName: String, zoneName: String, namespace: String) {
        self.accountID = accountID; self.containerIdentifier = containerIdentifier; self.database = database; self.zoneOwnerName = zoneOwnerName; self.zoneName = zoneName; self.namespace = namespace
    }
}
public struct SyncTransferContext: Sendable {
    public let scope: SyncOwnedFileScope
    let storeIdentity: UUID
    let configuration: SyncConfiguration
    let board: SharedBoardDescriptor?
    let accessGeneration: Int64
}
public final class SyncOwnedFileStaging: @unchecked Sendable {
    public let fileURL: URL
    public let descriptor: SyncOwnedFileDescriptor
    private let directory: URL
    private init(directory: URL, descriptor: SyncOwnedFileDescriptor) { self.directory = directory; self.fileURL = directory.appendingPathComponent("payload"); self.descriptor = descriptor }
    deinit { try? FileManager.default.removeItem(at: directory) }
    public static func create(data: Data, descriptor: SyncOwnedFileDescriptor) throws -> SyncOwnedFileStaging {
        try descriptor.validate()
        guard data.count == descriptor.byteCount, RepresentationStorage.digest(data) == descriptor.digest else { throw SyncError.invalidOperation }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ClipShelf-sync-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let result = SyncOwnedFileStaging(directory: directory, descriptor: descriptor)
        try data.write(to: result.fileURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.fileURL.path)
        return result
    }
    public static func copy(from fileURL: URL, descriptor: SyncOwnedFileDescriptor) throws -> SyncOwnedFileStaging {
        try create(data: readVerified(fileURL: fileURL, descriptor: descriptor), descriptor: descriptor)
    }
    static func readVerified(fileURL: URL, descriptor: SyncOwnedFileDescriptor) throws -> Data {
        try descriptor.validate()
        guard fileURL.isFileURL, !fileURL.path.contains("\0") else { throw SyncError.invalidOperation }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw SyncError.invalidOperation }
        defer { Darwin.close(directory) }
        // macOS exposes /var as a system alias. Canonicalize only that fixed prefix.
        var path = fileURL.path
        if path.hasPrefix("/var/") { path = "/private" + path }
        let components = URL(fileURLWithPath: path).pathComponents.dropFirst()
        guard let leaf = components.last else { throw SyncError.invalidOperation }
        for component in components.dropLast() {
            guard component != ".", component != ".." else { throw SyncError.invalidOperation }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw SyncError.invalidOperation }
            Darwin.close(directory); directory = next
        }
        let fd = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SyncError.invalidOperation }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == descriptor.byteCount else { throw SyncError.invalidOperation }
        let data = try handle.read(upToCount: descriptor.byteCount + 1) ?? Data()
        guard data.count == descriptor.byteCount, RepresentationStorage.digest(data) == descriptor.digest else { throw SyncError.invalidOperation }
        return data
    }
}
public struct PreparedSyncOwnedUpload: Sendable {
    public let operationID: UUID
    public let scope: SyncOwnedFileScope
    public let file: SyncOwnedFileDescriptor
    public let staging: SyncOwnedFileStaging
    public var fileURL: URL { staging.fileURL }
}
public struct SyncOwnedDownloadRequest: Sendable {
    public let operationID: UUID
    public let scope: SyncOwnedFileScope
    public let file: SyncOwnedFileDescriptor
    let context: SyncTransferContext
    public var transferID: String { operationID.uuidString + ":" + file.digest + ":" + file.filename }
}
public enum SyncOwnedTransferDirection: String, Codable, Sendable { case upload, download }
public enum SyncOwnedTransferStatus: String, Codable, Sendable { case pending, failed, complete }
public struct SyncOwnedTransferState: Sendable {
    public let operationID: UUID
    public let entityID: UUID
    public let scope: SyncOwnedFileScope
    public let file: SyncOwnedFileDescriptor
    public let direction: SyncOwnedTransferDirection
    public let status: SyncOwnedTransferStatus
    public let error: String?
}
public protocol SyncOwnedFileTransport: SyncTransport {
    func ownedFileScope(accountID: String) async throws -> SyncOwnedFileScope
    func uploadOwnedFile(_ upload: PreparedSyncOwnedUpload) async throws
    func downloadOwnedFile(_ request: SyncOwnedDownloadRequest) async throws -> SyncOwnedFileStaging
}
public protocol SharedBoardOwnedFileTransport: SharedBoardTransport {
    func ownedFileScope(board: SharedBoardDescriptor) async throws -> SyncOwnedFileScope
    func uploadOwnedFile(_ upload: PreparedSyncOwnedUpload, board: SharedBoardDescriptor) async throws
    func downloadOwnedFile(_ request: SyncOwnedDownloadRequest, board: SharedBoardDescriptor) async throws -> SyncOwnedFileStaging
}
