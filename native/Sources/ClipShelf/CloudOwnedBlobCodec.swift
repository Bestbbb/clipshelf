import ClipShelfCore
import CloudKit
import CryptoKit
import CoreFoundation
import Darwin
import Foundation

/// Lifetime-owned local copies: never let a CKAsset temporary URL escape a CloudKit response.
final class CloudAssetStaging: @unchecked Sendable {
    let directory: URL
    private let coordinator: StorageSpaceCoordinator
    private let writer: @Sendable (FileHandle, Data) throws -> Void
    private let lock = NSRecursiveLock()
    private var lease: StorageSpaceLease?
    private var valid = true
    private var writing = false
    init(spaceCoordinator: StorageSpaceCoordinator? = nil, temporaryDirectory: URL? = nil,
         writer: @escaping @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        let root = try SyncOwnedFileStaging.resolvedTemporaryDirectory(temporaryDirectory)
        coordinator = try spaceCoordinator ?? StorageSpaceCoordinator(directory: root.appendingPathComponent(".clipshelf-storage-reservations"))
        self.writer = writer
        directory = root
            .appendingPathComponent("ClipShelf-cloud-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { cleanup() }

    private func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        try? lease?.release(); lease = nil; valid = false
    }

    /// Reserve the complete stream before its first byte. An existing staging's original
    /// file and new chunks remain in the same aggregate claim until all its files are gone.
    func withWriteBudget<T>(bytes: Int, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid, !writing, bytes >= 0 else { throw SyncError.invalidOperation }
        do {
            try Task.checkCancellation()
            let requirement = StorageSpaceRequirement(destination: directory, bytes: Int64(bytes))
            if let lease { try lease.addRequirements([requirement]) }
            else { lease = try coordinator.reserve([requirement]) }
            writing = true; defer { writing = false }
            let result = try body()
            try Task.checkCancellation()
            try lease?.validateDestinations()
            return result
        } catch {
            cleanup()
            throw StorageWriteFailure.classify(error) ?? error
        }
    }

    /// Only called inside withWriteBudget. Empty-file creation does not stand in for stream budgeting.
    func createOutput(name: String) throws -> (URL, FileHandle) {
        guard writing, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw SyncError.invalidOperation }
        let url = directory.appendingPathComponent(name)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    func append(_ data: Data, to output: FileHandle) throws {
        guard writing else { throw SyncError.invalidOperation }
        try Task.checkCancellation()
        try writer(output, data)
    }

    func write(_ data: Data, name: String) throws -> URL {
        try withWriteBudget(bytes: data.count) {
            let (url, output) = try createOutput(name: name)
            defer { try? output.close() }
            try append(data, to: output)
            try output.synchronize()
            return url
        }
    }

    /// Bounds the opened regular inode before and during every read, rejecting links and FIFOs.
    static func withFile<T>(_ url: URL, maximum: Int, _ body: (FileHandle, Int) throws -> T) throws -> T {
        guard url.isFileURL, url.host == nil || url.host == "localhost", !url.path.contains("\0"), maximum >= 0 else { throw SyncError.invalidOperation }
        // macOS exposes these two system aliases in temporary asset URLs. All remaining
        // components, including any user-created intermediate link, are opened without following links.
        var path = url.path
        if path.hasPrefix("/var/") { path = "/private" + path }
        if path.hasPrefix("/tmp/") { path = "/private" + path }
        let components = URL(fileURLWithPath: path).pathComponents.dropFirst()
        guard let leaf = components.last, !leaf.isEmpty else { throw SyncError.invalidOperation }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw SyncError.invalidOperation }
        defer { Darwin.close(directory) }
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
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw SyncError.invalidOperation }
        guard info.st_size <= maximum else { throw HistoryStoreError.valueTooLarge }
        let value = try body(handle, Int(info.st_size))
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw SyncError.invalidOperation }
        return value
    }

    static func read(_ url: URL, maximum: Int) throws -> Data {
        try withFile(url, maximum: maximum) { handle, size in
            var result = Data(); result.reserveCapacity(size)
            while let bytes = try handle.read(upToCount: min(1_024 * 1_024, maximum - result.count + 1)), !bytes.isEmpty {
                try Task.checkCancellation()
                guard bytes.count <= maximum - result.count else { throw HistoryStoreError.valueTooLarge }
                result.append(bytes)
            }
            guard result.count == size else { throw SyncError.invalidOperation }
            return result
        }
    }
}

struct CloudOwnedBlobScope {
    let containerIdentifier: String
    let namespace: String
    let zoneID: CKRecordZone.ID
    let shared: Bool
    // A shared record belongs to the zone, not to its uploading participant. CKRecord.ID
    // validates the owner; writing __defaultOwner__ into payload metadata would break members.
    var kind: String { shared ? "shared" : "private" }
}

/// One immutable blob per digest in a zone. At most two 32 MiB assets preserve the Core
/// 64 MiB original-file budget without requiring a single asset above 32 MiB.
enum CloudOwnedBlobCodec {
    static let recordType = "ClipShelfOwnedFileV1"
    static let chunkBytes = 32 * 1_024 * 1_024
    static let maximumBytes = 64 * 1_024 * 1_024
    static let metadataKeys = ["sha256", "byteCount", "chunkCount", "formatVersion", "container", "namespace", "scopeKind", "zoneName"]
    static let assetKeys = ["chunk0", "chunk1"]
    static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func recordID(digest: String, scope: CloudOwnedBlobScope) -> CKRecord.ID {
        CKRecord.ID(recordName: "owned-" + digest, zoneID: scope.zoneID)
    }
    static func chunkCount(byteCount: Int) -> Int { max(1, (byteCount + chunkBytes - 1) / chunkBytes) }
    static func matches(_ record: CKRecord, digest: String, byteCount: Int, scope: CloudOwnedBlobScope) -> Bool {
        validDigest(digest) && (0...maximumBytes).contains(byteCount)
            && record.recordID == recordID(digest: digest, scope: scope) && record.recordType == recordType
            && record["sha256"] as? String == digest && exactInteger(record["byteCount"]) == byteCount
            && exactInteger(record["formatVersion"]) == 1 && exactInteger(record["chunkCount"]) == chunkCount(byteCount: byteCount)
            && record["container"] as? String == scope.containerIdentifier && record["namespace"] as? String == scope.namespace
            && record["scopeKind"] as? String == scope.kind && record["zoneName"] as? String == scope.zoneID.zoneName
            && (!scope.shared || record["account"] == nil)
    }
    static func isBlobDeletion(id: CKRecord.ID, type: String, scope: CloudOwnedBlobScope) -> Bool {
        id.zoneID == scope.zoneID && type == recordType && id.recordName.hasPrefix("owned-")
            && validDigest(String(id.recordName.dropFirst(6)))
    }
    static func validateMetadata(_ record: CKRecord, scope: CloudOwnedBlobScope) throws {
        guard let digest = record["sha256"] as? String, let count = exactInteger(record["byteCount"]),
              matches(record, digest: digest, byteCount: count, scope: scope) else { throw SyncError.invalidOperation }
    }
    static func exactInteger(_ value: CKRecordValue?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.int64Value),
              let result = Int(exactly: number.int64Value) else { return nil }
        return result
    }
    static func encode(file: URL, digest: String, byteCount: Int, scope: CloudOwnedBlobScope,
                       staging: CloudAssetStaging) throws -> CKRecord {
        guard validDigest(digest), (0...maximumBytes).contains(byteCount) else { throw SyncError.invalidOperation }
        let record = CKRecord(recordType: recordType, recordID: recordID(digest: digest, scope: scope))
        record["sha256"] = digest as NSString; record["byteCount"] = byteCount as NSNumber
        record["chunkCount"] = chunkCount(byteCount: byteCount) as NSNumber; record["formatVersion"] = 1 as NSNumber
        record["container"] = scope.containerIdentifier as NSString; record["namespace"] = scope.namespace as NSString
        record["scopeKind"] = scope.kind as NSString; record["zoneName"] = scope.zoneID.zoneName as NSString
        try staging.withWriteBudget(bytes: byteCount) {
            try CloudAssetStaging.withFile(file, maximum: maximumBytes) { input, size in
                guard size == byteCount else { throw SyncError.invalidOperation }
                var hash = SHA256(), total = 0
                for index in 0..<chunkCount(byteCount: byteCount) {
                    let (url, output) = try staging.createOutput(name: "chunk\(index)")
                    defer { try? output.close() }
                    let expected = min(chunkBytes, byteCount - total)
                    var written = 0
                    while written < expected {
                        try Task.checkCancellation()
                        guard let data = try input.read(upToCount: min(1_024 * 1_024, expected - written)), !data.isEmpty else { throw SyncError.invalidOperation }
                        hash.update(data: data); try staging.append(data, to: output); written += data.count
                    }
                    try output.synchronize(); total += written
                    record[assetKeys[index]] = CKAsset(fileURL: url)
                }
                guard (try input.read(upToCount: 1))?.isEmpty != false,
                      hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw SyncError.invalidOperation }
            }
        }
        return record
    }
    static func decode(_ record: CKRecord, digest: String, byteCount: Int, scope: CloudOwnedBlobScope,
                       staging: CloudAssetStaging) throws -> URL {
        guard matches(record, digest: digest, byteCount: byteCount, scope: scope) else { throw SyncError.invalidOperation }
        let count = chunkCount(byteCount: byteCount)
        if count == 1, record["chunk1"] != nil { throw SyncError.invalidOperation }
        return try staging.withWriteBudget(bytes: byteCount) {
            let (result, output) = try staging.createOutput(name: "payload")
            defer { try? output.close() }
            var hash = SHA256(), total = 0
            for index in 0..<count {
                guard let asset = record[assetKeys[index]] as? CKAsset, let url = asset.fileURL else { throw SyncError.invalidOperation }
                let expected = min(chunkBytes, byteCount - total)
                try CloudAssetStaging.withFile(url, maximum: chunkBytes) { input, size in
                    guard size == expected else { throw SyncError.invalidOperation }
                    var copied = 0
                    while let data = try input.read(upToCount: min(1_024 * 1_024, expected - copied + 1)), !data.isEmpty {
                        try Task.checkCancellation()
                        guard data.count <= expected - copied else { throw SyncError.invalidOperation }
                        try staging.append(data, to: output); hash.update(data: data); copied += data.count
                    }
                    guard copied == expected else { throw SyncError.invalidOperation }
                    total += copied
                }
            }
            guard total == byteCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw SyncError.invalidOperation }
            try output.synchronize()
            return result
        }
    }
}

/// The outer CloudKit version and the optional inner JSON version must agree. Keeping
/// legacy version absent (rather than adding 1) preserves old operation hashes on retry.
enum CloudOperationCodec {
    static let maximumBytes = 256 * 1_024 * 1_024
    static let metadataKeys = ["sha256", "account", "namespace", "formatVersion", "payloadByteCount"]
    static func version(_ data: Data) throws -> Int {
        struct Header: Decodable { let formatVersion: Int?; let ownedFiles: Manifest?; struct Manifest: Decodable {} }
        let header = try JSONDecoder().decode(Header.self, from: data)
        let version = header.formatVersion ?? 1
        guard version == 1 || version == 2, (version == 2) == (header.ownedFiles != nil) else { throw SyncError.invalidOperation }
        return version
    }
    static func matches(_ record: CKRecord, expected: CKRecord) -> Bool {
        record.recordID == expected.recordID && record.recordType == expected.recordType
            && record["sha256"] as? String == expected["sha256"] as? String
            && record["account"] as? String == expected["account"] as? String
            && record["namespace"] as? String == expected["namespace"] as? String
            && CloudOwnedBlobCodec.exactInteger(record["formatVersion"]) == CloudOwnedBlobCodec.exactInteger(expected["formatVersion"])
            && CloudOwnedBlobCodec.exactInteger(record["payloadByteCount"]) == CloudOwnedBlobCodec.exactInteger(expected["payloadByteCount"])
    }
    static func decode(_ record: CKRecord, type: String, namespace: String, shared: Bool, zone: CKRecordZone.ID) throws -> SyncOperation {
        guard record.recordID.zoneID == zone, record.recordType == type,
              record[shared ? "namespace" : "account"] as? String == namespace,
              (shared ? record["account"] == nil : record["namespace"] == nil),
              let outer = CloudOwnedBlobCodec.exactInteger(record["formatVersion"]), outer == 1 || outer == 2,
              let digest = record["sha256"] as? String, CloudOwnedBlobCodec.validDigest(digest),
              let file = (record["payload"] as? CKAsset)?.fileURL else { throw SyncError.invalidOperation }
        let data = try CloudAssetStaging.read(file, maximum: maximumBytes)
        // Existing v1 records have no length field; v2 always binds both digest and length.
        if outer == 2 || record["payloadByteCount"] != nil {
            guard CloudOwnedBlobCodec.exactInteger(record["payloadByteCount"]) == data.count else { throw SyncError.invalidOperation }
        }
        guard CloudSyncService.digest(data) == digest, try version(data) == outer else { throw SyncError.invalidOperation }
        let operation = try JSONDecoder().decode(SyncOperation.self, from: data)
        guard operation.operationID.uuidString == record.recordID.recordName, operation.accountID == namespace else { throw SyncError.invalidOperation }
        if let manifest = operation.ownedFiles {
            guard operation.action == .upsert, operation.entityKind == .clipboard, let item = operation.record else { throw SyncError.invalidOperation }
            try manifest.validate(record: item)
        }
        return operation
    }
}
