import Darwin
import Foundation
import CryptoKit

struct StorageSpaceNode: Codable, Equatable {
    let device: Int64
    let inode: UInt64
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let volumeUUID: String?

    init(_ value: stat, volumeUUID: String? = nil) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino); generation = value.st_gen
        birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        self.volumeUUID = volumeUUID
    }

    private enum CodingKeys: String, CodingKey { case device, inode, generation, birthSeconds, birthNanoseconds, volumeUUID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(Int64.self, forKey: .device)
        inode = try values.decode(UInt64.self, forKey: .inode)
        generation = try values.decode(UInt32.self, forKey: .generation)
        birthSeconds = try values.decode(Int64.self, forKey: .birthSeconds)
        birthNanoseconds = try values.decode(Int64.self, forKey: .birthNanoseconds)
        let stored = try values.decodeIfPresent(String.self, forKey: .volumeUUID)
        let binding = decoder.userInfo[StorageSpaceVolumeBinding.key] as? StorageSpaceVolumeBinding
        volumeUUID = stored ?? (binding?.legacyDevice == device ? binding?.volumeUUID : nil)
    }

    /// st_dev is a mount-time identifier. Persisted nodes on a UUID-backed volume
    /// keep their identity when macOS assigns that volume another device number.
    static func == (lhs: Self, rhs: Self) -> Bool {
        let sameVolume: Bool
        if let a = lhs.volumeUUID, let b = rhs.volumeUUID { sameVolume = a == b }
        else { sameVolume = lhs.volumeUUID == nil && rhs.volumeUUID == nil && lhs.device == rhs.device }
        return sameVolume && lhs.sameObject(as: rhs)
    }

    func sameObject(as other: Self) -> Bool {
        inode == other.inode && generation == other.generation &&
            birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
    }
}

/// Only supplied after a validated empty legacy registry has been bound to the
/// current volume. It is never used to accept an unknown or live legacy claim.
struct StorageSpaceVolumeBinding {
    static let key = CodingUserInfoKey(rawValue: "ClipShelf.storageVolumeBinding")!
    let legacyDevice: Int64
    let volumeUUID: String
}

enum StorageSpaceFiles {
    static func validURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.utf8.contains(0)
    }

    static func canonicalDirectory(_ url: URL) throws -> URL {
        guard validURL(url), let resolved = realpath(url.path, nil) else { throw StorageWriteFailure.destinationChanged }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let descriptor = try openDirectory(canonical)
        Darwin.close(descriptor)
        return canonical
    }

    /// All components of an already canonical path must remain directories, never links.
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard validURL(url) else { throw StorageWriteFailure.destinationChanged }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageWriteFailure.destinationChanged }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != ".." else { throw StorageWriteFailure.destinationChanged }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StorageWriteFailure.destinationChanged }
                Darwin.close(descriptor); descriptor = next
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    static func info(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw StorageWriteFailure.coordinationUnavailable }
        return value
    }

    static func privateNode(_ descriptor: Int32, directory: Bool) throws -> StorageSpaceNode {
        let value = try info(descriptor)
        guard value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), value.st_uid == geteuid(),
              value.st_mode & 0o077 == 0, directory || value.st_nlink == 1 else {
            throw StorageWriteFailure.coordinationUnavailable
        }
        return StorageSpaceNode(value, volumeUUID: StorageVolumeIdentity.uuid(for: descriptor))
    }

    static func matches(_ identity: StorageSpaceNode, name: String, directory: Int32) -> Bool {
        var value = stat()
        guard fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        if identity.volumeUUID == nil { return StorageSpaceNode(value) == identity }
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (value.st_mode & S_IFMT == S_IFDIR ? O_DIRECTORY : 0)
        let descriptor = openat(directory, name, flags)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard let opened = try? info(descriptor), StorageSpaceNode(opened) == StorageSpaceNode(value) else { return false }
        return StorageSpaceNode(opened, volumeUUID: StorageVolumeIdentity.uuid(for: descriptor)) == identity
    }

    static func exists(_ name: String, directory: Int32) throws -> Bool {
        var value = stat()
        if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw StorageWriteFailure.coordinationUnavailable }
        return false
    }

    static func lock(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw StorageWriteFailure.coordinationUnavailable
        }
    }

    static func names(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw StorageWriteFailure.coordinationUnavailable }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw StorageWriteFailure.coordinationUnavailable }
                return result
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw StorageWriteFailure.coordinationUnavailable }
            if name == "." || name == ".." { continue }
            guard result.count < 8_192 else { throw StorageWriteFailure.coordinationUnavailable }
            result.append(name)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, descriptor: Int32, volumeBinding: StorageSpaceVolumeBinding? = nil) throws -> T {
        let size = try info(descriptor).st_size
        guard size > 0, size <= 1_048_576 else { throw StorageWriteFailure.coordinationUnavailable }
        var data = Data(count: Int(size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StorageWriteFailure.coordinationUnavailable }
                offset += count
            }
        }
        do { return try decoder(volumeBinding).decode(type, from: data) }
        catch { throw StorageWriteFailure.coordinationUnavailable }
    }

    static func write<T: Encodable>(_ value: T, descriptor: Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw StorageWriteFailure.invalidRequirement }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pwrite(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                offset += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else { throw posixFailure() }
    }

    static func posixFailure() -> Error {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        return StorageWriteFailure.classify(error) ?? StorageWriteFailure.coordinationUnavailable
    }

    /// A checksum-invalid or incomplete slot is ignored only when the other slot supplies a
    /// complete preceding state. The caller never treats two invalid slots as an empty journal.
    static func readFrame<T: Decodable>(_ type: T.Type, descriptor: Int32, offset: Int64, maximumBytes: Int,
                                       volumeBinding: StorageSpaceVolumeBinding? = nil) throws -> T? {
        func bytes(_ count: Int, at offset: Int64) throws -> Data? {
            var data = Data(count: count)
            let complete = try data.withUnsafeMutableBytes { buffer -> Bool in
                var read = 0
                while read < count {
                    let result = pread(descriptor, buffer.baseAddress!.advanced(by: read), count - read, off_t(offset + Int64(read)))
                    if result < 0, errno == EINTR { continue }
                    guard result >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
                    if result == 0 { return false }
                    read += result
                }
                return true
            }
            return complete ? data : nil
        }
        guard let header = try bytes(40, at: offset) else { return nil }
        var length: UInt64 = 0
        for index in 0..<8 { length |= UInt64(header[index]) << (index * 8) }
        guard length > 0, length <= UInt64(maximumBytes), let payload = try bytes(Int(length), at: offset + 40),
              Data(SHA256.hash(data: payload)) == header.subdata(in: 8..<40) else { return nil }
        return try? decoder(volumeBinding).decode(type, from: payload)
    }

    private static func decoder(_ binding: StorageSpaceVolumeBinding?) -> JSONDecoder {
        let decoder = JSONDecoder()
        if let binding { decoder.userInfo[StorageSpaceVolumeBinding.key] = binding }
        return decoder
    }

    static func writeFrame<T: Encodable>(_ value: T, descriptor: Int32, offset: Int64, maximumBytes: Int) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count > 0, payload.count <= maximumBytes else { throw StorageWriteFailure.invalidRequirement }
        let length = UInt64(payload.count)
        var data = Data((0..<8).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        data.append(Data(SHA256.hash(data: payload))); data.append(payload)
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < data.count {
                let count = pwrite(descriptor, buffer.baseAddress!.advanced(by: written), data.count - written, off_t(offset + Int64(written)))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixFailure() }
    }
}

/// A caller-selected existing ancestor is resolved once. New path components below it cannot
/// become links or switch volumes, while normal creation of initially absent directories is allowed.
struct StorageSpaceDestination: Equatable {
    let originalAnchor: URL
    let canonicalAnchor: URL
    let identity: StorageSpaceNode
    let remainingComponents: [String]

    init(_ destination: URL) throws {
        guard StorageSpaceFiles.validURL(destination) else { throw StorageWriteFailure.invalidRequirement }
        var ancestor = destination.standardizedFileURL, remaining: [String] = []
        while true {
            var value = stat()
            if lstat(ancestor.path, &value) == 0 {
                if value.st_mode & S_IFMT == S_IFDIR { break }
                // Existing final files are written through their parent. Existing links are
                // never accepted as output locations, including a dangling final link.
                guard remaining.isEmpty, value.st_mode & S_IFMT == S_IFREG else { throw StorageWriteFailure.destinationChanged }
            } else if errno != ENOENT { throw StorageWriteFailure.destinationChanged }
            guard ancestor.path != "/" else { throw StorageWriteFailure.destinationChanged }
            remaining.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        originalAnchor = ancestor
        canonicalAnchor = try StorageSpaceFiles.canonicalDirectory(ancestor)
        let descriptor = try StorageSpaceFiles.openDirectory(canonicalAnchor)
        defer { Darwin.close(descriptor) }
        identity = StorageSpaceNode(try StorageSpaceFiles.info(descriptor))
        remainingComponents = remaining
    }

    func currentDirectory() throws -> URL {
        guard try StorageSpaceFiles.canonicalDirectory(originalAnchor) == canonicalAnchor else { throw StorageWriteFailure.destinationChanged }
        var descriptor = try StorageSpaceFiles.openDirectory(canonicalAnchor)
        defer { Darwin.close(descriptor) }
        guard StorageSpaceNode(try StorageSpaceFiles.info(descriptor)) == identity else { throw StorageWriteFailure.destinationChanged }
        var path = canonicalAnchor
        for (index, component) in remainingComponents.enumerated() {
            var value = stat()
            if fstatat(descriptor, component, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw StorageWriteFailure.destinationChanged }
                return path
            }
            if value.st_mode & S_IFMT == S_IFREG, index == remainingComponents.count - 1 { return path }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw StorageWriteFailure.destinationChanged }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw StorageWriteFailure.destinationChanged }
            guard StorageSpaceNode(try StorageSpaceFiles.info(next)) == StorageSpaceNode(value) else {
                Darwin.close(next); throw StorageWriteFailure.destinationChanged
            }
            Darwin.close(descriptor); descriptor = next; path.appendPathComponent(component, isDirectory: true)
        }
        return path
    }
}
